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
    callee_saved: Regs,
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

    pub fn debug(self: RegisterManager) void {
        var it = self.unused.iterator(.{ .kind = .unset });
        while (it.next()) |i| {
            log.debug("{} inused", .{@as(Register, @enumFromInt(i))});
        }
    }
    pub fn init(calleeSaveMask: Regs) RegisterManager {
        var dirty = calleeSaveMask;
        dirty.toggleAll();
        return RegisterManager{ .unused = Regs.initFull(), .insts = undefined, .dirty = dirty, .callee_saved = calleeSaveMask };
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
        var dirty = self.callee_saved;
        dirty.toggleAll();
        self.dirty = dirty;
    }
    pub fn getInst(self: *RegisterManager, reg: Register) usize {
        return self.insts[@intFromEnum(reg)];
    }
    pub fn getUnused(self: *RegisterManager, cconv: CallingConvention, inst: ?usize, cherry: Regs, file: std.fs.File.Writer) ?Register {
        return self.getUnusedExclude(cconv, inst, &.{}, cherry, file);
    }
    pub fn getUnusedExclude(self: *RegisterManager, cconv: CallingConvention, inst: ?usize, exclude: []const Register, cherry: Regs, file: std.fs.File.Writer) ?Register {
        var exclude_mask = Regs.initFull();
        for (exclude) |reg| {
            exclude_mask.unset(@intFromEnum(reg));
        }
        const res_mask = self.unused.intersectWith(exclude_mask).intersectWith(cherry);
        const reg: Register = @enumFromInt(res_mask.findFirstSet() orelse return null);
        self.markUsed(reg, inst);
        self.protectDirty(cconv, reg, file);
        return reg;
    }
    pub fn protectDirty(self: *RegisterManager, cconv: CallingConvention, reg: Register, file: std.fs.File.Writer) void {
        if (!self.isDirty(reg)) {
            self.markDirty(reg);
            cconv.saveDirty(reg, file);
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
    // Given the position and class of the argument, return the register for this argument,
    // or null if it should be passe on the stack
    
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
    double_data: usize,
    local_lable: usize,
    array: []usize,
    uninit,

    pub const StackTop = struct {
        off: isize,
        size: usize,
    };
    pub fn isMem(self: ResultLocation) bool {
        return switch (self) {
            .addr_reg,
            .stack_top,
            .stack_base => true,
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
            .addr_reg => |addr_reg| .{.addr_reg = AddrReg {.off = total_off + addr_reg.off, .reg = addr_reg.reg}},
            .stack_top => |stack_top| .{.stack_top = .{.off = total_off + stack_top.off, .size = stack_top.size}},
            .stack_base => |stack_base| .{.stack_base = stack_base + total_off},
            else => unreachable
        };
    }
    pub fn offsetByByte(self: ResultLocation, off: isize) ResultLocation {
        return switch (self) {
            .addr_reg => |addr_reg| .{.addr_reg = AddrReg {.off = off + addr_reg.off, .reg = addr_reg.reg}},
            .stack_top => |stack_top| .{.stack_top = .{.off = off + stack_top.off, .size = stack_top.size}},
            .stack_base => |stack_base| .{.stack_base = stack_base + off},
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
        writer.print("\t{s} {s}, ", .{ mov, reg.adapatSize(word) }) catch unreachable;
        self.print(writer, word) catch unreachable;
        writer.writeByte('\n') catch unreachable;
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, cconv: CallingConvention, off: isize, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager, results: []ResultLocation) void {
        return self.moveToAddrReg(cconv, AddrReg {.reg = .rbp, .off = off}, size, writer, reg_man, results);

    }

    pub fn moveToAddrReg(self: ResultLocation, cconv: CallingConvention, reg: AddrReg, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager, results: []ResultLocation) void {
        if (self == .uninit) return;
        if (Word.fromSize(size)) |word| {
            return self.moveToAddrRegWord(cconv, reg, word, writer, reg_man, results);
        }
        var self_clone = self;
        switch (self_clone) {
            .array => |array| {
                const sub_size = @divExact(size, array.len);
                for (array, 0..array.len) |el_inst, i| {
                    const loc = consumeResult(results, el_inst, reg_man, writer);
                    loc.moveToAddrReg(cconv, AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(sub_size * i))}, sub_size, writer, reg_man, results);
                }
                return;
            },
            inline .addr_reg,
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
                    self_clone.moveToAddrRegWord(cconv, AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(size - size_left))}, .qword, writer, reg_man, results);
                    off.* += reg_size;
                }
                self_clone.moveToAddrRegWord(cconv, AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(size - size_left))}, Word.fromSize(size_left).?, writer, reg_man, results);
            },
            else => unreachable
        }
    }
    pub fn moveToAddrRegWord(self: ResultLocation, cconv: CallingConvention, reg: AddrReg, word: Word, writer: std.fs.File.Writer, reg_man: *RegisterManager, _: []ResultLocation) void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) blk: {
            if (word == .qword) break :blk "movsd";
            if (word == .dword) break :blk "movss";
            unreachable;
        } else "mov";
        const temp_loc = switch (self) {
            inline .stack_base, .float_data, .double_data, .stack_top, .addr_reg  => |_| blk: {
                const temp_reg = reg_man.getUnused(cconv, null, RegisterManager.GpMask, writer) orelse @panic("TODO");
                self.moveToReg(temp_reg, writer, @intFromEnum(word));
                break :blk ResultLocation{ .reg = temp_reg };
            },
            .array => unreachable,
            else => self,
        };
        //log.err("mov {s}, temp_loc {}", .{mov, temp_loc});
        temp_loc.print(std.io.getStdOut().writer(), word) catch unreachable;
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
pub fn consumeResult(results: []ResultLocation, idx: usize, reg_mangager: *RegisterManager, writer: std.fs.File.Writer) ResultLocation {
    var loc = results[idx];
    switch (loc) {
        .reg => |reg| reg_mangager.markUnused(reg),
        .addr_reg, => |addr_reg| reg_mangager.markUnused(addr_reg.reg),
        .stack_top => |top_off| {
            writer.print("\tadd rsp, {}\n", .{top_off.size}) catch unreachable;
            loc.stack_top.off -= @as(isize, @intCast(top_off.size));
        },
        inline .float_data, .double_data, .string_data, .int_lit, .stack_base, .local_lable, .array, .uninit => |_| {},
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
            cconv: CallingConvention,
            self: Cir, 
            i: usize,
            curr_block: usize, 
            frame_size: *usize, 
            call: Cir.Inst.Call, 
            file: std.fs.File.Writer, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void,  
        prolog: *const fn (
            cconv: CallingConvention,
            self: Cir, 
            file: std.fs.File.Writer, 
            frame_size: *usize, 
            scope_size: *usize, 
            curr_block: usize, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void,  
        epilog: *const fn (
            cconv: CallingConvention,
            file: std.fs.File.Writer, 
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
        self: Cir, 
        i: usize,
        curr_block: usize, 
        frame_size: *usize, 
        call: Cir.Inst.Call, 
        file: std.fs.File.Writer, 
        reg_manager: *RegisterManager, 
        results: []ResultLocation) void {
        cconv.vtable.call(cconv, self, i, curr_block, frame_size, call, file, reg_manager, results);
    }
    pub fn prolog(cconv: CallingConvention, self: Cir, file: std.fs.File.Writer, frame_size: *usize, scope_size: *usize, curr_block: usize, reg_manager: *RegisterManager, results: []ResultLocation) void {
        cconv.vtable.prolog(cconv, self, file, frame_size, scope_size, curr_block, reg_manager, results);
    }
    pub fn epilog(            
        cconv: CallingConvention,
        file: std.fs.File.Writer, 
        reg_manager: *RegisterManager, 
        results: []ResultLocation, 
        ret_t: Type,
        i: usize) void {
        cconv.vtable.epilog(cconv, file, reg_manager, results, ret_t, i);
    }
    pub fn saveDirty(self: CallingConvention, reg: Register, file: std.fs.File.Writer) void {
        file.print("\tmov [rbp + {}], {}\n", .{ -@as(isize, @intCast((self.vtable.calleeSavedPos(reg) + 1) * 8)), reg }) catch unreachable;
    }
    pub fn restoreDirty(self: CallingConvention, reg: Register, file: std.fs.File.Writer) void {
        file.print("\tmov {}, [rbp + {}]\n", .{ reg, -@as(isize, @intCast((self.vtable.calleeSavedPos(reg) + 1) * 8)) }) catch unreachable;
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
            cconv: CallingConvention,
            self: Cir, file: std.fs.File.Writer, frame_size: *usize, scope_size: *usize, curr_block: usize, reg_manager: *RegisterManager, results: []ResultLocation) void {

            _ = cconv;
            var int_ct: u8 = 0;
            var float_ct: u8 = 0;
            // basic setup
            file.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)}) catch unreachable;
            file.print("\tpush rbp\n\tmov rbp, rsp\n", .{}) catch unreachable;
            var curr_idx: usize = 1;
            frame_size.* = alignStack(getFrameSize(self, 0, &curr_idx) + CalleeSaveRegs.len * 8);
            file.print("\tsub rsp, {}\n", .{frame_size}) catch unreachable;
            scope_size.* = CalleeSaveRegs.len * 8;
            reg_manager.markCleanAll();
            reg_manager.markUnusedAll();

            // allocate return
            // Index 1 of insts is always the ret_decl
            if (self.ret_type != TypePool.@"void") {
                const ret_classes = CDecl.classifyType(self.ret_type);
                if (ret_classes.len > 2) @panic("Type larger than 2 eightbytes should be passed via stack");
                if (ret_classes.get(0) == .mem) {
                    const reg = CDecl.getArgLoc(reg_manager, 0, .int).?;
                    self.insts[curr_block].block_start = alignAlloc2(self.insts[curr_block].block_start, PTR_SIZE, PTR_SIZE);
                    scope_size.* = alignAlloc2(scope_size.*, PTR_SIZE, PTR_SIZE);
                    const off = -@as(isize, @intCast(scope_size.*));
                    file.print("\tmov [rbp + {}], {}\n", .{ off, reg }) catch unreachable;
                    results[1] = ResultLocation{ .stack_base = @as(isize, @intCast(off)) };   
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
                    self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, t);
                    scope_size.* = alignAlloc(scope_size.*, t);
                    break :blk -@as(isize, @intCast(scope_size.*));
                } else blk: {
                    break :blk undefined;
                };
                // The offset from the stack base to next argument on the stack (ONLY sensible to the argument that ARE passed via the stack)
                // Starts with PTR_SIZE because "push rbp"
                var arg_stackbase_off: usize = PTR_SIZE * 2;
                // TODO: this should be done in reverse order
                for (arg_classes.slice(), 0..) |class, eightbyte| {
                    const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
                    switch (class) {
                        .int => {
                            const reg = getArgLoc(reg_manager, int_ct, class).?;
                            int_ct += 1;
                            file.print("\tmov [rbp + {}], {}\n", .{class_off , reg }) catch unreachable;
                            results[2 + arg_pos] = ResultLocation{ .stack_base = off };
                        },
                        .sse => {
                            const reg = getArgLoc(reg_manager, float_ct, class).?;
                            float_ct += 1;
                            file.print("\tmovsd [rbp + {}], {}\n", .{class_off , reg }) catch unreachable;
                            results[2 + arg_pos] = ResultLocation{ .stack_base = off };
                        },
                        .mem => {
                            const sub_size = typeSize(t);
                            const sub_align = alignOf(t);
                            arg_stackbase_off = (arg_stackbase_off + sub_align - 1) / sub_align * sub_align;
                            results[2 + arg_pos] = ResultLocation{ .stack_base = @intCast(arg_stackbase_off) };
                            arg_stackbase_off += sub_size;

                        },
                .none => unreachable,
                    }
                }
            }
        }
        pub fn epilog(
            cconv: CallingConvention,
            file: std.fs.File.Writer, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation, 
            ret_t: Type,
            i: usize) void {
            const ret_size = typeSize(ret_t);
            if (ret_t != TypePool.@"void") {
                const loc = consumeResult(results, i - 1, reg_manager, file);
                const ret_classes = classifyType(ret_t);
                for (ret_classes.constSlice(), 0..) |class, class_pos| {
                    switch (class) {
                        .int => {
                            const reg = getRetLocInt(reg_manager, @intCast(class_pos));
                            if (reg_manager.isUsed(reg)) unreachable;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, file, PTR_SIZE);
                            } else {
                                log.debug("loc {}", .{loc});
                                loc.moveToReg(reg, file, PTR_SIZE);
                            }
                        },
                        .sse => {
                            const reg = getRetLocSse(reg_manager, @intCast(class_pos));
                            if (reg_manager.isUsed(reg)) unreachable;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, file, PTR_SIZE);
                            } else {
                                loc.moveToReg(reg, file, PTR_SIZE);
                            }
                        },
                        .mem => {
                            const reg = getRetLocInt(reg_manager, 0);
                            // Assume that ret_loc is always the first location on the stack
                            const ret_loc = ResultLocation {.stack_base = -PTR_SIZE };
                            ret_loc.moveToReg(reg, file, PTR_SIZE);
                            loc.moveToAddrReg(cconv, AddrReg {.reg = reg, .off = 0}, ret_size, file, reg_manager, results);

                        },
                            .none => unreachable,
                    }
                }
            }

            var it = reg_manager.dirty.intersectWith(CalleeSaveMask).iterator(.{});
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);
                cconv.restoreDirty(reg, file);
            }
            file.print("\tleave\n", .{}) catch unreachable;
            file.print("\tret\n", .{}) catch unreachable;

        }
        pub fn makeCall(
            cconv: CallingConvention,
            self: Cir, 
            i: usize,
            curr_block: usize, 
            frame_size: *usize, 
            call: Cir.Inst.Call, 
            file: std.fs.File.Writer, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void {
            const caller_used = CallerSaveMask.differenceWith(reg_manager.unused);
            const callee_unused = CalleeSaveMask.intersectWith(reg_manager.unused);
            var it = caller_used.iterator(.{ .kind = .set });
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);

                const inst = reg_manager.getInst(reg);

                const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));

                reg_manager.markUnused(reg);
                reg_manager.markUsed(dest_reg, inst);
                reg_manager.protectDirty(cconv, dest_reg, file);

                ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, file, 8);
                results[inst] = switch (results[inst]) {
                    .reg => |_| ResultLocation {.reg = dest_reg},
                    .addr_reg => |old_addr| ResultLocation {.addr_reg = AddrReg {.off = old_addr.off, .reg = dest_reg}},
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
                    call_int_ct += 1;
                    const tsize = typeSize(call.t);
                    const align_size = alignStack(tsize);
                    file.print("\tsub rsp, {}\n", .{align_size}) catch unreachable;
                    const reg = getArgLoc(reg_manager, 0, .int).?;
                    file.print("\tmov {}, rsp\n", .{reg}) catch unreachable;

                }
            }

            // Move each argument operand into the right register
            var arg_stack_allocation: usize = 0;
            // TODO: this should be done in reverse order
            for (call.args) |arg| {
                const loc = results[arg.i];

                if (loc != .stack_top) _ = consumeResult(results, arg.i, reg_manager, file);
                const arg_classes = classifyType(arg.t);
                //const arg_t_full = TypePool.lookup(arg.t);
                //log.debug("arg {}", .{arg_t_full});
                //for (arg_classes.constSlice()) |class| {
                //    log.debug("class {}", .{class});
                //}
                if (arg_classes.get(0) == .mem) {
                    const new_arg_stack = alignStack(alignAlloc(arg_stack_allocation, arg.t));
                    file.print("\tsub rsp, {}\n", .{new_arg_stack - arg_stack_allocation}) catch unreachable;
                    //const reg = reg_manager.getUnused(i, RegisterManager.GpRegs, file);
                    //reg_manager.markUnused(reg);
                    loc.moveToAddrReg(cconv, .{.reg = .rsp, .off = 0}, typeSize(arg.t), file, reg_manager, results);
                    arg_stack_allocation = new_arg_stack;

                }
                for (arg_classes.slice(), 0..) |class, class_pos| {
                    switch (class) {
                        .int => {
                            const reg = getArgLoc(reg_manager, call_int_ct, .int).?;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, file, PTR_SIZE);
                            } else {
                                loc.moveToReg(reg, file, PTR_SIZE);
                            }
                            call_int_ct += 1;
                        },
                        .sse => {
                            const reg = getArgLoc(reg_manager, call_float_ct, .sse).?;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, file, PTR_SIZE);
                            } else {
                                loc.moveToReg(reg, file, PTR_SIZE);
                            }
                            call_float_ct += 1;
                        },
                        .mem => {
                    },
                    .none => unreachable,
                    }
                }
            }




            file.print("\tmov rax, {}\n", .{call_float_ct}) catch unreachable;
            const arg_stack_allocation_aligned = alignStack(arg_stack_allocation);
            file.print("\tsub rsp, {}\n", .{arg_stack_allocation_aligned - arg_stack_allocation}) catch unreachable;
            file.print("\tcall {s}\n", .{Lexer.lookup(call.name)}) catch unreachable; // TODO handle return 

            file.print("\tadd rsp, {}\n", .{arg_stack_allocation_aligned}) catch unreachable;
            // ResultLocation
            if (call.t != TypePool.@"void") {
                const ret_classes = classifyType(call.t).constSlice();
                if (ret_classes.len > 1) {
                    const realloc = alignStack(typeSize(call.t));
                    self.insts[curr_block].block_start += realloc;
                    frame_size.* += realloc;
                    file.print("\tsub rsp, {}\n", .{realloc}) catch unreachable;
                    for (ret_classes, 0..) |class, pos| {
                        switch (class) {
                            .int => {
                                file.print("\tmov qword PTR [rsp + {}], {}\n", .{pos * PTR_SIZE, getRetLocInt(reg_manager, @intCast(pos))}) catch unreachable;
                            },
                            .sse => {
                                file.print("\tmovsd qword PTR [rsp + {}], {}\n", .{pos * PTR_SIZE, getRetLocSse(reg_manager, @intCast(pos))}) catch unreachable;
                            },
                            .mem, .none => unreachable,
                        }
                    }
                    results[i] = ResultLocation {.stack_top = .{ .off = 0, .size = alignStack(typeSize(call.t)) }};
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
                        .mem => {
                            results[i] = ResultLocation {.stack_top = .{ .off = 0, .size = alignStack(typeSize(call.t)) }};
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
                @panic("TODO: register already inused, save it somewhere");
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
            cconv: CallingConvention,
            self: Cir, file: std.fs.File.Writer, frame_size: *usize, scope_size: *usize, curr_block: usize, reg_manager: *RegisterManager, results: []ResultLocation) void {

            _ = cconv;
            var int_ct: u8 = 0;
            var float_ct: u8 = 0;

            file.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)}) catch unreachable;
            file.print("\tpush rbp\n\tmov rbp, rsp\n", .{}) catch unreachable;
            var curr_idx: usize = 1;
            frame_size.* = alignStack(getFrameSize(self, 0, &curr_idx) + CalleeSaveRegs.len * 8);
            file.print("\tsub rsp, {}\n", .{frame_size.*}) catch unreachable;
            scope_size.* = CalleeSaveRegs.len * 8;
            reg_manager.markCleanAll();
            reg_manager.markUnusedAll();

            // allocate return
            // Index 1 of insts is always the ret_decl
            if (self.ret_type != TypePool.@"void") {
                const ret_class = classifyType(self.ret_type);
                if (ret_class == .mem) {
                    const reg = getArgLoc(reg_manager, 0, .int).?;
                    self.insts[curr_block].block_start = alignAlloc2(self.insts[curr_block].block_start, PTR_SIZE, PTR_SIZE);
                    scope_size.* = alignAlloc2(scope_size.*, PTR_SIZE, PTR_SIZE);
                    const off = -@as(isize, @intCast(scope_size.*));
                    file.print("\tmov [rbp + {}], {}\n", .{ off, reg }) catch unreachable;
                    results[1] = ResultLocation{ .stack_base = @as(isize, @intCast(off)) };   
                    int_ct += 1;
                } else {
                    results[1] = ResultLocation.uninit;
                }
            }

            for (self.arg_types, 0..) |t, arg_pos| {
                // generate instruction for all the arguments
                var arg_class = classifyType(t);
                if (int_ct + float_ct >= 4) arg_class = .mem;
                // For argumennt already passed via stack, there is no need to allocate another space on stack for it
                const off = if (arg_class != .mem) blk: {
                    self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, t);
                    scope_size.* = alignAlloc(scope_size.*, t);
                    break :blk -@as(isize, @intCast(scope_size.*));
                } else blk: {
                    break :blk undefined;
                };
                // The offset from the stack base to next argument on the stack (ONLY sensible to the argument that ARE passed via the stack)
                // Starts with PTR_SIZE because "push rbp"
                var arg_stackbase_off: usize = PTR_SIZE * 2;
                // TODO: this should be done in reverse order
                //const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
                switch (arg_class) {
                    .int => {
                        const reg = getArgLoc(reg_manager, int_ct, arg_class).?;
                        int_ct += 1;
                        file.print("\tmov [rbp + {}], {}\n", .{off , reg }) catch unreachable;
                        results[2 + arg_pos] = ResultLocation{ .stack_base = off };
                    },
                    .sse => {
                        const reg = getArgLoc(reg_manager, float_ct, arg_class).?;
                        float_ct += 1;
                        file.print("\tmovsd [rbp + {}], {}\n", .{off , reg }) catch unreachable;
                        results[2 + arg_pos] = ResultLocation{ .stack_base = off };
                    },
                    .mem => {
                        const sub_size = typeSize(t);
                        const sub_align = alignOf(t);
                        arg_stackbase_off = (arg_stackbase_off + sub_align - 1) / sub_align * sub_align;
                        results[2 + arg_pos] = ResultLocation{ .stack_base = @intCast(arg_stackbase_off) };
                        arg_stackbase_off += sub_size;

                    },
                .none => unreachable,
                }
            }
        }
        pub fn epilog(
            cconv: CallingConvention,
            file: std.fs.File.Writer, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation, 
            ret_t: Type,
            i: usize) void {

            const ret_size = typeSize(ret_t);
            if (ret_t != TypePool.@"void") {
                const loc = consumeResult(results, i - 1, reg_manager, file);
                const ret_class = classifyType(ret_t);
                switch (ret_class) {
                    .int => {
                        const reg = getRetLocInt(reg_manager);
                        if (reg_manager.isUsed(reg)) unreachable;
                        //log.debug("loc {}", .{loc});
                        loc.moveToReg(reg, file, PTR_SIZE);
                    },
                    .sse => {
                        const reg = getRetLocSse(reg_manager);
                        if (reg_manager.isUsed(reg)) unreachable;
                        loc.moveToReg(reg, file, PTR_SIZE);
                    },
                    .mem => {
                        const reg = getRetLocInt(reg_manager);
                        // Assume that ret_loc is always the first location on the stack
                        const ret_loc = ResultLocation {.stack_base = -PTR_SIZE };
                        ret_loc.moveToReg(reg, file, PTR_SIZE);
                        loc.moveToAddrReg(cconv, AddrReg {.reg = reg, .off = 0}, ret_size, file, reg_manager, results);

                    },
                    .none => unreachable,
                }
            }

            var it = reg_manager.dirty.intersectWith(CalleeSaveMask).iterator(.{});
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);
                cconv.restoreDirty(reg, file);
            }
            file.print("\tleave\n", .{}) catch unreachable;
            file.print("\tret\n", .{}) catch unreachable;

        }
        pub fn makeCall(
            cconv: CallingConvention,
            self: Cir, 
            i: usize,
            curr_block: usize, 
            frame_size: *usize, 
            call: Cir.Inst.Call, 
            file: std.fs.File.Writer, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void {
            _ = self;
            _ = curr_block;
            _ = frame_size;
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
                reg_manager.protectDirty(cconv, dest_reg, file);

                ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, file, 8);
                results[inst] = switch (results[inst]) {
                    .reg => |_| ResultLocation {.reg = dest_reg},
                    .addr_reg => |old_addr| ResultLocation {.addr_reg = AddrReg {.off = old_addr.off, .reg = dest_reg}},
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
                // On return, %rax will contain the address that has been passed in by the calledr in %rdi
                if (ret_class == .mem) {
                    call_int_ct += 1;
                    const tsize = typeSize(call.t);
                    const align_size = alignStack(tsize);
                    file.print("\tsub rsp, {}\n", .{align_size}) catch unreachable;
                    const reg = getArgLoc(reg_manager, 0, .int).?;
                    file.print("\tmov {}, rsp\n", .{reg}) catch unreachable;
                }
            }

            // Move each argument operand into the right register
            // According to Microsoft, the caller is supposd to allocate 32 bytes of `shadow space`, below the stack args
            const SHADOW_SPACE = 32;
            file.print("\tsub rsp, {}\n", .{SHADOW_SPACE}) catch unreachable;
            var arg_stack_allocation: usize = 0;
            // TODO: this should be done in reverse order
            for (call.args) |arg| {
                const loc = results[arg.i];

                if (loc != .stack_top) _ = consumeResult(results, arg.i, reg_manager, file);
                var arg_class = classifyType(arg.t);
                if (call_int_ct + call_float_ct >= 4) arg_class = .mem;
                //const arg_t_full = TypePool.lookup(arg.t);
                //log.debug("arg {}", .{arg_t_full});
                //for (arg_classes.constSlice()) |class| {
                //    log.debug("class {}", .{class});
                //}
                blk: switch (arg_class) {
                    .int => {
                        const reg = getArgLoc(reg_manager, call_int_ct, .int).?;
                        loc.moveToReg(reg, file, PTR_SIZE);
                        call_int_ct += 1;
                    },
                    // https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#varargs
                    // for varargs, floating-point values must also be duplicate into the integer register
                    .sse => {
                        const reg = getArgLoc(reg_manager, call_float_ct, .sse).?;
                        loc.moveToReg(reg, file, PTR_SIZE);
                        call_float_ct += 1;
                        if (call.name == Lexer.printf) continue :blk .int;
                    },
                    .mem => {
                        const new_arg_stack = alignStack(alignAlloc(arg_stack_allocation, arg.t));
                        file.print("\tsub rsp, {}\n", .{new_arg_stack - arg_stack_allocation}) catch unreachable;
                        //const reg = reg_manager.getUnused(i, RegisterManager.GpRegs, file);
                        //reg_manager.markUnused(reg);
                        loc.moveToAddrReg(cconv, .{.reg = .rsp, .off = 0}, typeSize(arg.t), file, reg_manager, results);
                        arg_stack_allocation = new_arg_stack;

                    },
                    .none => unreachable,
                }
            }




            //file.print("\tmov rax, {}\n", .{call_float_ct}) catch unreachable;
            const arg_stack_allocation_aligned = alignStack(arg_stack_allocation);
            file.print("\tsub rsp, {}\n", .{arg_stack_allocation_aligned - arg_stack_allocation}) catch unreachable;
            file.print("\tcall {s}\n", .{Lexer.lookup(call.name)}) catch unreachable; // TODO handle return 

            file.print("\tadd rsp, {}\n", .{arg_stack_allocation_aligned + SHADOW_SPACE}) catch unreachable;
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
                        results[i] = ResultLocation {.stack_top = .{ .off = 0, .size = alignStack(typeSize(call.t)) }};
                    },
                    .none => unreachable,
                }
            }
        }
    };


};
pub fn compileAll(cirs: []Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) !void {
    try file.print(builtinText, .{});

    var string_data = std.AutoArrayHashMap(Symbol, usize).init(alloc);
    defer string_data.deinit();
    var double_data = std.AutoArrayHashMap(u64, usize).init(alloc);
    defer double_data.deinit();
    var float_data = std.AutoArrayHashMap(u32, usize).init(alloc);
    defer float_data.deinit();


    var label_ct: usize = 0;

    const cconv = switch (os) {
        .linux => CallingConvention.CDecl.interface(),
        .windows => CallingConvention.FastCall.interface(),
        else => @panic("Unsupported OS, only linux and windows is supported"),
    };
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
        try compile(pgm_entry, file, &string_data, &double_data, &float_data, &label_ct, cconv, alloc);

    }
    for (cirs) |cir| {
        try compile(cir, file, &string_data, &double_data, &float_data, &label_ct, cconv, alloc);
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
    alloc: std.mem.Allocator) !void {
    log.debug("compiling \"{s}\"", .{Lexer.lookup(self.name)});
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init(cconv.callee_saved);
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

    var scope_size: usize = 0;
    var frame_size: usize = 0;
    var curr_block: usize = 0;

    cconv.prolog(self, file, &frame_size, &scope_size, curr_block, &reg_manager, results);

    for (self.insts, 0..) |_, i| {
        reg_manager.debug();
        log.debug("[{}] {}", .{ i, self.insts[i] });
        try file.print("# [{}] {}\n", .{i, self.insts[i]});
        switch (self.insts[i]) {
            //.function => |*f| {
            //    try file.print("{s}:\n", .{Lexer.string_pool.lookup(f.name)});
            //    try file.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
            //    var curr_idx = i + 2;
            //    f.frame_size = self.getFrameSize(i + 1, &curr_idx) + RegisterManager.CalleeSaveRegs.len * 8;
            //    f.frame_size = (f.frame_size + 15) / 16 * 16; // align stack to 16 byte
            //    try file.print("\tsub rsp, {}\n", .{f.frame_size});
            //    scope_size = RegisterManager.CalleeSaveRegs.len * 8;
            //    reg_manager.markCleanAll();
            //    reg_manager.markUnusedAll();

            //    int_ct = 0;
            //    float_ct = 0;



            //},
            .ret => |ret| {
                cconv.epilog(file, &reg_manager, results, ret.t, i);
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
                //const v = switch (self.insts[var_access]) {
                //    .var_decl => |v| v,
                //    .arg_decl => |v| v,
                //    else => unreachable,
                //};
                const loc = results[var_access];
                //if (v.auto_deref) {
                //    const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                //    loc.moveToReg(reg, file, PTR_SIZE);
                //    results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
                //} else {
                //    results[i] = loc;

                //}
                results[i] = loc;
            },
            .var_assign => |var_assign| {
                const var_loc = consumeResult(results, var_assign.lhs, &reg_manager, file);
                var expr_loc = consumeResult(results, var_assign.rhs, &reg_manager, file);
                switch (var_loc) {
                    .stack_base => |off| expr_loc.moveToStackBase(cconv, off, typeSize(var_assign.t), file, &reg_manager, results),
                    .addr_reg => |reg| expr_loc.moveToAddrReg(cconv, reg, typeSize(var_assign.t), file, &reg_manager, results),
                    else => unreachable,
                }

            },
            .ret_decl => |t| {
                _ = t;
                //    const t_full = TypePool.lookup(t);
                //    switch (t_full) {
                //        .array, .tuple, .named => {
                //            const reg = reg_manager.getArgLoc(0, .int).?;
                //            self.insts[curr_block].block_start = alignAlloc2(self.insts[curr_block].block_start, PTR_SIZE, PTR_SIZE);
                //            scope_size = alignAlloc2(scope_size, PTR_SIZE, PTR_SIZE);
                //            const off = -@as(isize, @intCast(scope_size));
                //            try file.print("\tmov [rbp + {}], {}\n", .{ off, reg });
                //            results[i] = ResultLocation{ .stack_base = @as(isize, @intCast(off)) };   
                //            int_ct += 1;
                //        },
                //        else => {},
                //    }

            },
            .arg_decl => |*v| {
                _ = v;
                //    // TODO handle differnt type
                //    // TODO handle different number of argument
                //    // The stack (and some registers) upon a function call
                //    //
                //    // sub rsp, [amount of stack memory need for arguments]
                //    // mov [rsp+...], arguments
                //    // jmp foo
                //    // push rbp
                //    // mov rbp, rsp <- rbp for the calle
                //    // sub rsp, [amount of stack memory]
                //    //
                //    // (+ => downwards, - => upwards)
                //    // -------- <- rsp of the callee
                //    // callee stack ...
                //    // -------- <- rbp of the callee
                //    // rbp of the caller saved (PTR_SIZE)
                //    // -------- rsp of the caller immediately before and after the call instruction
                //    // leftmost argument on stack
                //    // ...
                //    // rightmost argument on stack
                //    // -------- rsp of the caller before the call and after the cleanup of the call
                //    const t = v.t;
                //    self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, t);
                //    scope_size = alignAlloc(scope_size, t);
                //    const off = -@as(isize, @intCast(scope_size));

                //    const arg_classes = classifyType(t);
                //    for (arg_classes.slice(), 0..) |class, eightbyte| {
                //        const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
                //        switch (class) {
                //            .int => {
                //                const reg = reg_manager.getArgLoc(int_ct, class).?;
                //                int_ct += 1;
                //                try file.print("\tmov [rbp + {}], {}\n", .{class_off , reg });
                //                results[i] = ResultLocation{ .stack_base = class_off };
                //            },
                //            .sse => {
                //                const reg = reg_manager.getArgLoc(float_ct, class).?;
                //                float_ct += 1;
                //                try file.print("\tmov [rbp + {}], {}\n", .{class_off , reg });
                //                results[i] = ResultLocation{ .stack_base = class_off };
                //            },
                //            .mem => {
                //                results[i] = ResultLocation{ .stack_base = class_off };
                //            },
                //            .none => unreachable,
                //        }
                //    }
            },
            .call => |call| {
                // reg_manager.markUnusedAll(); // TODO caller saved register
                // Save any caller save registers that are in-use, and mark them as unuse

                cconv.makeCall(self, i, curr_block, &frame_size, call, file, &reg_manager, results);

            },
            .add,
            .sub,
            .mul,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
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
                    const new_reg = reg_manager.getUnusedExclude(cconv, other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(cconv, other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                const rhs_reg = reg_manager.getUnusedExclude(cconv, null, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
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
                const result_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                const temp_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");

                lhs_loc.moveToReg(result_reg, file, 4);
                rhs_loc.moveToReg(temp_reg, file, 4);
                const op = switch (self.insts[i]) {
                    .addf => "addss",
                    .subf => "subss",
                    .mulf => "mulss",
                    .divf => "divss",
                    else => unreachable,
                };
                try file.print("\t{s} {}, {}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .addd,
            .subd,
            .muld,
            .divd,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const result_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                const temp_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");

                lhs_loc.moveToReg(result_reg, file, 8);
                rhs_loc.moveToReg(temp_reg, file, 8);
                const op = switch (self.insts[i]) {
                    .addd => "addsd",
                    .subd => "subsd",
                    .muld => "mulsd",
                    .divd => "divsd",
                    else => unreachable,
                };
                try file.print("\t{s} {}, {}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .eq, .lt, .gt => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                lhs_loc.moveToReg(reg, file, PTR_SIZE);
                try file.print("\tcmp {}, ", .{reg});
                try rhs_loc.print(file, .byte);
                try file.writeByte('\n');
                try file.print("\tsete {}\n", .{reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .eqf, .ltf, .gtf => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                lhs_loc.moveToReg(reg, file, 4);
                try file.print("\tcomiss {}, ", .{reg});
                try rhs_loc.print(file, .dword);
                try file.writeByte('\n');

                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                try file.print("\tsete {}\n", .{res_reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .eqd, .ltd, .gtd => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                lhs_loc.moveToReg(reg, file, 8);
                try file.print("\tcomisd {}, ", .{reg});
                try rhs_loc.print(file, .qword);
                try file.writeByte('\n');

                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                try file.print("\tsete {}\n", .{res_reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .not => |rhs| {
                const rhs_loc = consumeResult(results, rhs, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                rhs_loc.moveToReg(reg, file, typeSize(TypePool.@"bool"));
                try file.print("\ttest {}, {}\n", .{reg, reg});
                try file.print("\tsetz {}\n", .{reg.lower8()});
                results[i] = ResultLocation {.reg = reg};
            },
            .i2d => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_int_reg = reg_manager.getUnused(cconv, null, RegisterManager.GpMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_int_reg, file, typeSize(TypePool.double));
                try file.print("\tcvtsi2sd {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_float_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, file, typeSize(TypePool.int));
                try file.print("\tcvtsd2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .i2f => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_int_reg = reg_manager.getUnused(cconv, null, RegisterManager.GpMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_int_reg, file, typeSize(TypePool.float));
                try file.print("\tcvtsi2ss {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_float_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, file, typeSize(TypePool.int));
                try file.print("\tcvtss2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2d => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_float_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, file, typeSize(TypePool.float));
                try file.print("\tcvtss2sd {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2f => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_float_reg = reg_manager.getUnused(cconv, null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(cconv, i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, file, typeSize(TypePool.double));
                try file.print("\tcvtsd2ss {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer label_ct.* += 1;
                const loc = consumeResult(results, if_start.expr, &reg_manager, file);
                results[i] = ResultLocation{ .local_lable = label_ct.* };

                const jump = switch (self.insts[if_start.expr]) {
                    .eq, .eqf, .eqd => "jne",
                    .lt, .ltf, .ltd => "jae",
                    .gt, .gtf, .gtd => "jbe",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(cconv, null, RegisterManager.GpMask, file) orelse @panic("TODO");
                        loc.moveToReg(temp_reg, file, typeSize(TypePool.bool));
                        try file.print("\tcmp {}, 0\n", .{temp_reg});
                        break :blk "je";
                    },
                };
                try file.print("\t{s} .L{}\n", .{ jump, label_ct.* });
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
                defer label_ct.* += 1;
                results[i] = ResultLocation{ .local_lable = label_ct.* };

                try file.print(".W{}:\n", .{label_ct.*});
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
                const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse unreachable;
                loc.moveAddrToReg(reg, file);
                results[i] = ResultLocation {.reg = reg};
            },
            .deref => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file) orelse unreachable;
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
                blk: switch (array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
                        const reg = reg_manager.getUnused(cconv, i, RegisterManager.GpMask, file).?;
                        results[ptr].moveToReg(reg, file, PTR_SIZE);
                        results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
                    },
                    .loc => |loc| results[i] = results[loc],
                    .none => {
                        const align_size = alignStack(typeSize(array_init.t));
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
                    .stack_base => |stack_base| loc.moveToStackBase(cconv, stack_base, sub_size, file, &reg_manager, results),
                    .stack_top => |stack_top| loc.moveToAddrReg(cconv, .{ .off = stack_top.off, .reg = .rsp }, sub_size, file, &reg_manager, results),
                    .addr_reg => |addr_reg| loc.moveToAddrReg(cconv, addr_reg, sub_size, file, &reg_manager, results),
                    else => unreachable
                }
            },
            .array_init_end => |array_init| {
                blk: switch (self.insts[array_init].array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
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
