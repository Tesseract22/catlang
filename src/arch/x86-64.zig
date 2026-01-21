const std = @import("std");
const Allocator = std.mem.Allocator;
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

fn offsetStackTop(writer: *std.Io.Writer, offset: isize) void {
    writer.print("\tadd rsp, {}\n", .{ offset }) catch unreachable;
}

fn storeRegAddr(writer: *std.Io.Writer, addr: AddrReg, word: Word, src: Register) void {
    writer.print("\tmov {f}, {f}\n", .{ print(addr, word), src }) catch unreachable;
}

fn loadRegAddr(writer: *std.Io.Writer, addr: AddrReg, word: Word, dst: Register) void {
    writer.print("\tmov {f}, {f}\n", .{ dst, print(addr, word) }) catch unreachable;
}


fn printAddrReg(writer: *std.Io.Writer, addr: AddrReg, word: Word) void {
    if (addr.mul) |mul| 
        writer.print("{s} PTR [{f} + {f} * {} + {}]", .{@tagName(word), addr.reg, mul[0], @intFromEnum(mul[1]), addr.disp}) catch unreachable
    else
        writer.print("{s} PTR [{f} + {}]", .{@tagName(word), addr.reg, addr.disp}) catch unreachable;
}


fn printDataLoc(writer: *std.Io.Writer, idx: usize, prefix: []const u8) void {
    writer.print(".{s}{}[rip]", .{ prefix, idx }) catch unreachable;
}

fn printIntLit(writer: *std.Io.Writer, int: isize) void {
    writer.print("{}", .{ int }) catch unreachable;
}

fn printForeignLabel(writer: *std.Io.Writer, name: []const u8) void {
    writer.print("{s}[rip]", .{ name }) catch unreachable;
}

fn moveAddrToRegImpl(rm: *RegisterManager, addr: AddrReg, word: Word, dst: Register) void {

    rm.print("\tlea {f}, {f}\n", .{ dst, print(addr, word) });
}
pub fn printLoc(writer: *std.Io.Writer, loc: ResultLocation, word: Word) void {
    switch (loc) {
        .reg => |reg| writer.print("{s}", .{reg.adaptSize(word)}) catch unreachable,
        .addr_reg => |addr| writer.print("{f}", .{print(addr, word)}) catch unreachable,
        .int_lit => |i| writer.print("{}", .{i}) catch unreachable,
        .string_data => |s| printDataLoc(writer, s, "s"),
        .float_data => |f| printDataLoc(writer, f, "f"),
        .double_data => |d| printDataLoc(writer, d, "d"),
        .foreign => |foreign| writer.print("{s}[rip]", .{ Lexer.lookup(foreign) }) catch unreachable,
        inline .local_lable, .array => |_| @panic("TODO"),
        .uninit => unreachable,
    }
}

fn selectMoveLocToReg(src: ResultLocation, dst: Register, size: usize) ?[]const u8 {
    if (src == .uninit) return null;
    const word = Word.fromSize(size).?;
    if (dst.isFloat()) {
        if (word == .qword) return "movsd";
        if (word == .dword) return "movss";
        @panic("unsupported float type");
    }
    const mov: []const u8 = switch (src) {
        .reg => |src_reg|
            if (src_reg == dst) return null
            else if (src_reg.isFloat()) 
                switch (word) {
                    .qword => "movq",
                    .dword => "movd",
                    .word, .byte => "mov",
                }
            else "mov",
        //inline .stack_base, .stack_top, .addr_reg => |_| {if (size != 8) mov = "movzx";},
        .string_data => "lea",
        .array => @panic("TODO"),
        else => "mov",
    };
    
    return mov;
}

fn moveLocToRegImpl(rm: *RegisterManager, src: ResultLocation, dst: Register, size: usize) void {
    const mov = selectMoveLocToReg(src, dst, size) orelse return;
    const word = Word.fromSize(size).?;
    rm.print("{s}, {f}, {f}", .{ mov, dst, print(src, word) });
}

pub fn moveLocToAddrRegImpl(rm: *RegisterManager, src: ResultLocation, addr: AddrReg, word: Word) void {
    const mov = if (src == ResultLocation.reg and src.reg.isFloat()) blk: {
        if (word == .qword) break :blk "movsd";
        if (word == .dword) break :blk "movss";
        unreachable;
    } else "mov";
    const temp_loc = switch (src) {
        inline .string_data, .float_data, .double_data, .addr_reg => |_| blk: {
            const temp_reg = rm.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
            moveLocToReg(src, temp_reg, @intFromEnum(word), rm);
            break :blk ResultLocation{ .reg = temp_reg };
        },
        .array => unreachable,
        else => src,
    };
    rm.print("\t{s} {f}, {f}\n", .{ mov, print(addr, word), print(temp_loc, word) });
}

const rm_table = Arch.RMTable(Register) {
    .offset_stack_top = offsetStackTop,
    .store_reg_addr = storeRegAddr,
    .load_reg_addr = loadRegAddr,
};

const mov_table = Arch.MovTable(STACK_ALIGNMENT, PTR_SIZE, Register, rm_table) {
    .mov_addr_to_reg = moveAddrToRegImpl,
    .mov_loc_to_reg = moveLocToRegImpl,
    .mov_loc_to_addr_reg = moveLocToAddrRegImpl,
};

const p_table = Arch.PrintTable(Register) {
    .print_loc = printLoc,
    .print_addr_reg = printAddrReg,
};



const Details = Arch.ArchDetails(STACK_ALIGNMENT, PTR_SIZE, Register, rm_table, mov_table);

const Word = Arch.Word;
const RegisterManager = Arch.RegisterManagerT(Register, PTR_SIZE, STACK_ALIGNMENT, rm_table);
const CallingConvention = RegisterManager.CallingConvention;
const ResultLocation = Arch.ResultLocationT(Register);
const AddrReg = Arch.AddrRegT(Register);
const print = Arch.Print(Register, p_table).print;
const alignAllocRaw = Arch.alignAllocRaw;

const Sizes = Arch.SizeFn(PTR_SIZE, STACK_ALIGNMENT);
const typeSize = Sizes.typeSize;
const alignOf = Sizes.alignOf;

const moveLocToStackBase = Details.moveLocToStackBase;
const moveLocToAddrReg = Details.moveLocToAddrReg;
const moveLocToReg = Details.moveLocToReg;

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
        pub fn format(value: Lower8, writer: *std.Io.Writer) !void {
            _ = try writer.writeAll(@tagName(value));
        }
    };
    pub const Lower16 = enum {
        ax,
        bx,
        cx,
        dx,
        si,
        di,
        bp,
        sp,
        r8w,
        r9w,
        r10w,
        r11w,
        r12w,
        r13w,
        r14w,
        r15w,
        pub fn format(value: Lower16, writer: *std.Io.Writer) !void {
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
        pub fn format(value: Lower32, writer: *std.Io.Writer) !void {
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
    pub fn lower16(self: Register) Lower16 {
        return @enumFromInt(@intFromEnum(self));
    }
    pub fn lower32(self: Register) Lower32 {
        return @enumFromInt(@intFromEnum(self));
    }
    pub fn adaptSize(self: Register, word: Word) []const u8 {
        return switch (word) {
            .byte => @tagName(self.lower8()),
            .word => @tagName(self.lower16()),
            .dword => @tagName(self.lower32()),
            .qword => @tagName(self),
        };
    }


    pub const DivendReg = Register.rax;
    pub const DivQuotient = Register.rax;
    pub const DivRemainder = Register.rdx;

    pub fn format(value: Register, writer: *std.Io.Writer) !void {
        _ = try writer.writeAll(@tagName(value));
    }
};

const Class = enum { // A simplified version of the x86-64 System V ABI classification algorithms
    int, // int
    sse, // float
         //sse_up, This is used when passing vector argument (_m256,_float128,etc.), but there is no such thing in our language
    none, // intialized with this
    mem, // passed via allocating memory on stack
};
const bounded_array = @import("../bounded_array.zig");
pub const CDecl = struct {
    pub const CallerSaveRegs = [_]Register{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 };
    pub const CalleeSaveRegs = [_]Register{ .rbx, .r12, .r13, .r14, .r15 };
    pub const CallerSaveMask = RegisterManager.cherryPick(&CallerSaveRegs);
    pub const CalleeSaveMask = RegisterManager.cherryPick(&CalleeSaveRegs);


    // The Classification Algorithm
    // Each eightbyte (or 64 bits, becaus 64 bits fit exactly into a normal register) is classified individually, then merge
    const MAX_CLASS = PTR_SIZE * 8; // Anything more tan 
    const ClassResult = bounded_array.BoundedArray(Class, MAX_CLASS);

    pub fn interface() CallingConvention {
        return .{.vtable = .{.call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog }, .callee_saved = CalleeSaveMask};
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
            log.err("{f} already in used", .{reg});
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
                log.err("Unreachable type {f}", .{t_full});
                unreachable;
            },
        }
    } 
    pub fn prolog(
        self: Cir, 
        reg_man: *RegisterManager, 
        results: []ResultLocation
    ) void {
        var int_ct: u8 = 0;
        var float_ct: u8 = 0;
        reg_man.markCleanAll();
        reg_man.markUnusedAll();

        // allocate return
        // Index 1 of insts is always the ret_decl
        if (self.ret_type != TypePool.@"void") {
            const ret_classes = CDecl.classifyType(self.ret_type);
            if (ret_classes.len > 2) @panic("Type larger than 2 eightbytes should be passed via stack");
            if (ret_classes.get(0) == .mem) {
                const reg = CDecl.getArgLoc(reg_man, 0, .int).?;
                const stack_pos = reg_man.allocateStack(PTR_SIZE, PTR_SIZE);
                reg_man.print("\tmov [rbp + {}], {f}\n", .{ stack_pos, reg });
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
                break :blk reg_man.allocateStackTyped(t);
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
                        const reg = getArgLoc(reg_man, int_ct, class).?;
                        int_ct += 1;
                        const loc = ResultLocation {.reg = reg };
                        moveLocToStackBase(loc, class_off, @min(arg_size, PTR_SIZE), reg_man);
                        results[2 + arg_pos] = ResultLocation.stackBase(off);
                    },
                    .sse => {
                        const reg = getArgLoc(reg_man, float_ct, class).?;
                        float_ct += 1;
                        const loc = ResultLocation {.reg = reg };
                        moveLocToStackBase(loc, class_off, @min(arg_size, PTR_SIZE), reg_man);
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
            const loc = reg_manager.consumeResult(i - 1);
            const ret_classes = classifyType(ret_t);
            for (ret_classes.constSlice(), 0..) |class, class_pos| {
                switch (class) {
                    .int => {
                        const reg = getRetLocInt(reg_manager, @intCast(class_pos));
                        if (reg_manager.isUsed(reg)) unreachable;
                        if (loc.isMem()) {
                            moveLocToReg(loc.offsetByByte(@intCast(class_pos * PTR_SIZE)), reg, PTR_SIZE, reg_manager);
                        } else {
                            moveLocToReg(loc, reg, PTR_SIZE, reg_manager);
                        }
                    },
                    .sse => {
                        const reg = getRetLocSse(reg_manager, @intCast(class_pos));
                        if (reg_manager.isUsed(reg)) unreachable;
                        if (loc.isMem()) {
                            moveLocToReg(loc.offsetByByte(@intCast(class_pos * PTR_SIZE)), reg, PTR_SIZE, reg_manager);
                        } else {
                            moveLocToReg(loc, reg, PTR_SIZE, reg_manager);
                        }
                    },
                    .mem => {
                        const reg = getRetLocInt(reg_manager, 0);
                        // Assume that ret_loc is always the first location on the stack
                        const ret_loc = results[1];
                        moveLocToReg(ret_loc, reg, PTR_SIZE, reg_manager);
                        moveLocToAddrReg(loc, AddrReg {.reg = reg, .disp = 0}, ret_size, reg_manager);

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
        var it = caller_used.iterator(.{ .kind = .set });
        while (it.next()) |regi| {
            const callee_unused = CalleeSaveMask.intersectWith(reg_manager.unused);
            const reg: Register = @enumFromInt(regi);
            const inst = reg_manager.getInst(reg);
            const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));

            reg_manager.markUnused(reg);
            reg_manager.markUsed(dest_reg, inst);
            reg_manager.protectDirty(dest_reg);

            moveLocToReg(.{ .reg = reg }, dest_reg, 8, reg_manager);
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
                reg_manager.print("\tlea {f}, [rbp + {}]\n", .{reg, stack_pos});

            }
        }

        // Move each argument operand into the right register
        var arg_stack_allocation: usize = 0;
        // TODO: this should be done in reverse order
        //
        //
        for (call.locs, call.ts) |loc_i, t| {
            const loc = reg_manager.consumeResult(loc_i);
            const arg_classes = classifyType(t);
            //const arg_t_full = TypePool.lookup(arg.t);
            //log.debug("arg {}", .{arg_t_full});
            //for (arg_classes.constSlice()) |class| {
            //    log.debug("class {}", .{class});
            //}
            // Needs to pass this thing by pushing it onto the stack
            // Notice in the fastcall calling convention, we needs to pass it as a reference
            if (arg_classes.get(0) == .mem) {
                _ = reg_manager.allocateStackTempTyped(t);
                //const reg = reg_manager.getUnused(i, RegisterManager.GpRegs);
                //reg_manager.markUnused(reg);
                moveLocToAddrReg(loc, .{.reg = .rsp, .disp = 0}, typeSize(t), reg_manager);
                arg_stack_allocation += 1;

            }
            for (arg_classes.slice(), 0..) |class, class_pos| {
                switch (class) {
                    .int => {
                        log.debug("\targ {}", .{loc});
                        const reg = getArgLoc(reg_manager, call_int_ct, .int).?;
                        if (loc.isMem()) {
                            moveLocToReg(loc.offsetByByte(@intCast(class_pos * PTR_SIZE)), reg, PTR_SIZE, reg_manager);
                        } else {
                            moveLocToReg(loc, reg, PTR_SIZE, reg_manager);
                        }
                        call_int_ct += 1;
                    },
                    .sse => {
                        const reg = getArgLoc(reg_manager, call_float_ct, .sse).?;
                        if (loc.isMem()) {
                            moveLocToReg(loc.offsetByByte(@intCast(class_pos * PTR_SIZE)), reg, PTR_SIZE, reg_manager);
                        } else {
                            moveLocToReg(loc, reg, PTR_SIZE, reg_manager);
                        }
                        call_float_ct += 1;
                    },
                    .mem => {},
                    .none => unreachable,
                }
            }
        }




        reg_manager.print("\tmov rax, {}\n", .{call_float_ct});
        const func_res = reg_manager.consumeResult(call.func);
        switch (func_res) {
            .foreign => |foreign| {
                reg_manager.print("\tcall {s}\n", .{Lexer.lookup(foreign)});
            },
            else => {
                const reg = reg_manager.getUnused(null, CalleeSaveMask).?;
                moveLocToReg(func_res, reg, PTR_SIZE, reg_manager);
                reg_manager.print("\tcall {f}\n", .{reg});
            }
        }
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
                            reg_manager.print("\tmov qword PTR [rbp + {}], {f}\n", .{ret_stack + @as(isize, @intCast(pos * PTR_SIZE)), getRetLocInt(reg_manager, @intCast(pos))});
                        },
                        .sse => {
                            reg_manager.print("\tmovsd qword PTR [rbp + {}], {f}\n", .{ret_stack + @as(isize, @intCast(pos * PTR_SIZE)), getRetLocSse(reg_manager, @intCast(pos))});
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
        return .{.vtable = .{.call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog }, .callee_saved = CalleeSaveMask};
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
                log.err("Unreachable type {f}", .{t_full});
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
            log.err("{f} already in used", .{reg});
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
        reg_man: *RegisterManager, 
        results: []ResultLocation
    ) void {
        var reg_arg_ct: u8 = 0;

        reg_man.markCleanAll();
        reg_man.markUnusedAll();

        // allocate return
        // Index 1 of insts is always the ret_decl
        if (self.ret_type != TypePool.@"void") {
            const ret_class = classifyType(self.ret_type);
            if (ret_class == .mem) {
                const reg = getArgLoc(reg_man, 0, .int).?;
                const stack_pos = reg_man.allocateStack(PTR_SIZE, PTR_SIZE);
                reg_man.print("\tmov [rbp + {}], {f}\n", .{ stack_pos, reg });
                results[1] = ResultLocation.stackBase(stack_pos);   
                reg_arg_ct += 1;
            } else {
                results[1] = ResultLocation.uninit;
            }
        }

        for (self.arg_types, 0..) |t, arg_pos| {
            // generate instruction for all the arguments
            const arg_class = classifyType(t);
            // For argumennt already passed via stack, there is no need to allocate another space on stack for it
            // The offset from the stack base to next argument on the stack (ONLY sensible to the argument that ARE passed via the stack)
            // Starts with PTR_SIZE because "push rbp"
            //var arg_stackbase_off: usize = PTR_SIZE * 2;
            // TODO: this should be done in reverse order
            //const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
            var stack_arg_off: usize = 2 * PTR_SIZE + SHADOW_SPACE;
            var stack_shadow_usage: usize = 2 * PTR_SIZE;
            if (reg_arg_ct >= 4) {
                switch (arg_class) {
                    .int, .sse => {
                        results[2 + arg_pos] = ResultLocation.stackBase(@intCast(stack_arg_off));
                        stack_arg_off = alignAllocRaw(stack_arg_off, typeSize(t), @max(alignOf(t), PTR_SIZE));
                    },
                    .mem => {
                        results[2 + arg_pos] = ResultLocation.stackBase(@intCast(stack_arg_off));
                        stack_arg_off = alignAllocRaw(stack_arg_off, PTR_SIZE, PTR_SIZE);
                        self.insts[2 + arg_pos].arg_decl.auto_deref = true;
                    },
                    .none => unreachable,
                }
            } else {
                switch (arg_class) {
                    .int => {
                        const reg = getArgLoc(reg_man, reg_arg_ct, arg_class).?;
                        const loc = ResultLocation {.reg = reg};
                        moveLocToStackBase(loc, @intCast(stack_shadow_usage), typeSize(t), reg_man);
                        results[2 + arg_pos] = ResultLocation.stackBase(@intCast(stack_shadow_usage));
                    },
                    .sse => {
                        const reg = getArgLoc(reg_man, reg_arg_ct, arg_class).?;
                        const loc = ResultLocation {.reg = reg};
                        moveLocToStackBase(loc, @intCast(stack_shadow_usage), typeSize(t), reg_man);
                        results[2 + arg_pos] = ResultLocation.stackBase(@intCast(stack_shadow_usage));
                    },
                    .mem => {
                        const reg = getArgLoc(reg_man, reg_arg_ct, .int).?;
                        const loc = ResultLocation {.reg = reg};
                        moveLocToStackBase(loc, @intCast(stack_shadow_usage), PTR_SIZE, reg_man);
                        results[2 + arg_pos] = ResultLocation.stackBase(@intCast(stack_shadow_usage));
                        self.insts[2 + arg_pos].arg_decl.auto_deref = true;
                    },
                    .none => unreachable,
                }
                reg_arg_ct += 1;
                stack_shadow_usage = alignAllocRaw(stack_shadow_usage, PTR_SIZE, PTR_SIZE);
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
            const loc = reg_manager.consumeResult(i - 1);
            const ret_class = classifyType(ret_t);
            switch (ret_class) {
                .int => {
                    const reg = getRetLocInt(reg_manager);
                    if (reg_manager.isUsed(reg)) unreachable;
                    reg_manager.markUsed(reg, i);
                    //log.debug("loc {}", .{loc});
                    moveLocToReg(loc, reg, ret_size, reg_manager);
                    reg_manager.markUnused(reg);
                },
                .sse => {
                    const reg = getRetLocSse(reg_manager);
                    if (reg_manager.isUsed(reg)) unreachable;
                    reg_manager.markUsed(reg, i);
                    moveLocToReg(loc, reg, ret_size, reg_manager);
                    reg_manager.markUnused(reg);
                },
                .mem => {
                    const reg = getRetLocInt(reg_manager);
                    if (reg_manager.isUsed(reg)) unreachable;
                    reg_manager.markUsed(reg, i);
                    // Assume that ret_loc is always the first location on the stack
                    const ret_loc = results[1];
                    moveLocToReg(ret_loc, reg, PTR_SIZE, reg_manager);
                    moveLocToAddrReg(loc, AddrReg {.reg = reg, .disp = 0}, ret_size, reg_manager);

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
    fn calStackTemp(call: Cir.Inst.Call) usize {
        var usage: usize = 0;
        var reg_arg_ct: usize = 0;
        for (call.ts) |t| {
            const arg_class = classifyType(t);
            if (reg_arg_ct >= 4) {
                switch (arg_class) {
                    .int, .sse => {
                        usage = alignAllocRaw(usage, typeSize(t), @max(alignOf(t), PTR_SIZE));
                    },
                    .mem => {
                        usage = alignAllocRaw(usage, PTR_SIZE, PTR_SIZE);
                    },
                    .none => unreachable,
                }
            } else {
                reg_arg_ct += 1;
            }
        }
        return usage;
    }
    const SHADOW_SPACE = 32;
    pub fn makeCall(
        i: usize,
        call: Cir.Inst.Call, 
        reg_man: *RegisterManager, 
        results: []ResultLocation) void {
        // TODO: factor this out
        reg_man.print("\t# Caller Saved\n", .{});
        const caller_used = CallerSaveMask.differenceWith(reg_man.unused);
        var it = caller_used.iterator(.{ .kind = .set });
        while (it.next()) |regi| {
            const callee_unused = CalleeSaveMask.intersectWith(reg_man.unused);
            const reg: Register = @enumFromInt(regi);

            const inst = reg_man.getInst(reg);

            const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));

            reg_man.markUnused(reg);
            reg_man.markUsed(dest_reg, inst);
            reg_man.protectDirty(dest_reg);

            moveLocToReg(.{ .reg = reg }, dest_reg, PTR_SIZE, reg_man);
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
        var reg_arg_ct: u8 = 0;
        if (call.t != TypePool.@"void") {
            const ret_class = classifyType(call.t);
            // If the class of the return type is mem, a pointer to the stack is passed to %rdi as if it is the first argument
            // On return, %rax will contain the address that has been passed in by the calledr in %rdi
            if (ret_class == .mem) {
                // TODO: use temporary stack memory
                reg_arg_ct += 1;
                const ret_mem = reg_man.allocateStackTyped(call.t);
                const reg = getArgLoc(reg_man, 0, .int).?;
                reg_man.print("\tlea {f}, [rbp + {}]\n", .{reg, ret_mem});

            }
        }
        reg_man.print("\t# Move Args\n", .{});
        _ = reg_man.allocateStackTemp(calStackTemp(call) + SHADOW_SPACE, STACK_ALIGNMENT);
        var tmp_stack_usage: usize = SHADOW_SPACE;
        // Move each argument operand into the right register
        // According to Microsoft, the caller is supposd to allocate 32 bytes of `shadow space`, below the stack args
        for (call.locs, call.ts) |loc_i, t| {
            const loc = reg_man.consumeResult(loc_i);
            const arg_class = classifyType(t);
            const arg_size = typeSize(t);
            if (reg_arg_ct >= 4) {
                switch (arg_class) {
                    .int, .sse => {
                        moveLocToAddrReg(loc, .{.reg = .rsp, .disp = @intCast(tmp_stack_usage) }, arg_size, reg_man);
                        tmp_stack_usage = alignAllocRaw(tmp_stack_usage, arg_size, @max(alignOf(t), PTR_SIZE));
                    },
                    .mem => {
                        const off = reg_man.allocateStackTyped(t);
                        moveLocToStackBase(loc, off, arg_size, reg_man);
                        const tmp_reg = reg_man.getUnused(null, RegisterManager.GpMask).?;
                        reg_man.print("\tlea {f}, [rbp + {}]\n", .{tmp_reg, off});
                        reg_man.print("\tmov qword PTR [rsp + {}], {f}\n", .{tmp_stack_usage, tmp_reg});
                        tmp_stack_usage = alignAllocRaw(tmp_stack_usage, PTR_SIZE, PTR_SIZE);
                    },
                    .none => unreachable,
                }
            } else {
                switch (arg_class) {
                    .int => {
                        const reg = getArgLoc(reg_man, reg_arg_ct, .int).?;
                        moveLocToReg(loc, reg, arg_size, reg_man);
                    },
                    // https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#varargs
                    // for varargs, floating-point values must also be duplicate into the integer register
                    .sse => {
                        const reg = getArgLoc(reg_man, reg_arg_ct, .sse).?;
                        moveLocToReg(loc, reg, arg_size, reg_man);
                        if (call.varadic) {
                            const reg_int = getArgLoc(reg_man, reg_arg_ct, .int).?;
                            moveLocToReg(loc, reg_int, arg_size, reg_man);
                        }
                    },
                    // for 
                    .mem => {
                        // To make this a temporary allocation, we need to allocate this BEFORE we move the args
                        const off = reg_man.allocateStackTyped(t);
                        moveLocToStackBase(loc, off, arg_size, reg_man);
                        const reg = getArgLoc(reg_man, reg_arg_ct, .int).?;
                        reg_man.print("\tlea {f}, [rbp + {}]\n", .{reg, off});
                    },
                    .none => unreachable,
                }
                reg_arg_ct += 1;
            }
        }
        const func_res = reg_man.consumeResult(call.func);
        switch (func_res) {
            .foreign => |foreign| {
                reg_man.print("\tcall {s}\n", .{Lexer.lookup(foreign)});
            },
            else => {
                const reg = reg_man.getUnused(null, CalleeSaveMask).?;
                moveLocToReg(func_res, reg, PTR_SIZE, reg_man);
                reg_man.print("\tcall {f}\n", .{reg});
            }
        }
        reg_man.freeStackTemp();
        // ResultLocation
        if (call.t != TypePool.@"void") {
            const ret_class = classifyType(call.t);
            switch (ret_class) {
                .int => {
                    reg_man.markUsed(.rax, i);
                    results[i] = ResultLocation{ .reg = .rax };
                },
                .sse => {
                    reg_man.markUsed(.xmm0, i);
                    results[i] = ResultLocation{ .reg = .xmm0 };
                },
                .mem => {
                    results[i] = ResultLocation {.addr_reg = .{.reg = .rax, .disp = 0} };
                },
                .none => unreachable,
            }
        }
    }
};

pub const OutputBuffer = std.ArrayList(u8);
pub fn compileAll(cirs: []Cir, file: *std.Io.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) Arch.CompileError!void {
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
        .linux => CDecl.interface(),
        .windows => FastCall.interface(),
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
        log.debug("string data: {}", .{entry.value_ptr.*});
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
    try file.flush();
}
pub fn compile(
    self: Cir, 
    file: *std.Io.Writer, 
    string_data: *std.AutoArrayHashMap(Symbol, usize), 
    double_data: *std.AutoArrayHashMap(u64, usize), 
    float_data: *std.AutoArrayHashMap(u32, usize),
    label_ct: *usize,
    cconv: CallingConvention,
    alloc: std.mem.Allocator,
    prologue: bool) Arch.CompileError!void {
    log.line(.debug);
    log.debug("cir: ===== {s} =====", .{Lexer.lookup(self.name)});
    var body_buffer = std.Io.Writer.Allocating.init(alloc);
    const body_writer = &body_buffer.writer;

    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;
    defer alloc.free(results);


    var reg_manager = RegisterManager.init(cconv, body_writer, alloc, results);
    defer {
        if (reg_manager.temp_stack.items.len != 0) {
            @panic("not all tempory stack is free");
        }

        file.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)}) catch unreachable;
        if (prologue) {
            file.print("\tpush rbp\n\tmov rbp, rsp\n", .{}) catch unreachable;
            file.print("\tsub rsp, {}\n", .{Sizes.alignStack(reg_manager.max_usage)}) catch unreachable;
        }
        //log.note("frame usage {}", .{reg_manager.frame_usage});


        file.writeAll(body_buffer.written()) catch unreachable;
        body_buffer.deinit();
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
        log.debug("[{}] {f}", .{ i, self.insts[i] });
        reg_manager.print("# [{}] {f}\n", .{i, self.insts[i]});
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

                // var loc = reg_manager.consumeResult(i - 1);
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
                    moveLocToReg(loc, reg, PTR_SIZE, &reg_manager);
                    results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
                } else {
                    results[i] = loc;

                }
            },
            .var_assign => |var_assign| {
                const var_loc = results[var_assign.lhs];
                const expr_loc = results[var_assign.rhs];
                //log.note("expr_loc {}", .{expr_loc});
                switch (var_loc) {
                    .addr_reg => |reg| moveLocToAddrReg(expr_loc, reg, typeSize(var_assign.t), &reg_manager),
                    else => unreachable,
                }
                _ = reg_manager.consumeResult(var_assign.lhs);
                _ = reg_manager.consumeResult(var_assign.rhs);

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
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                moveLocToReg(lhs_loc, reg, 8, &reg_manager);

                const op = switch (self.insts[i]) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "imul",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {f}, {f}\n", .{ op, reg, print(rhs_loc, .qword) });

                results[i] = ResultLocation{ .reg = reg };
            },
            .mod, .div => |bin_op| {
                const exclude = [_]Register{ Register.DivendReg, Register.DivQuotient, Register.DivRemainder };
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    moveLocToReg(results[other_inst], new_reg, 8, &reg_manager);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    moveLocToReg(results[other_inst], new_reg, 8, &reg_manager);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                const rhs_reg = reg_manager.getUnusedExclude(null, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                moveLocToReg(lhs_loc, Register.DivendReg, 8, &reg_manager);
                reg_manager.print("\tmov edx, 0\n", .{});
                moveLocToReg(rhs_loc, rhs_reg, 8, &reg_manager);
                reg_manager.print("\tidiv {f}\n", .{rhs_reg});

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
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");

                moveLocToReg(lhs_loc, result_reg, 4, &reg_manager);
                moveLocToReg(rhs_loc, temp_reg, 4, &reg_manager);
                const op = switch (self.insts[i]) {
                    .addf => "addss",
                    .subf => "subss",
                    .mulf => "mulss",
                    .divf => "divss",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {f}, {f}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .addd,
            .subd,
            .muld,
            .divd,
            => |bin_op| {
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");

                moveLocToReg(lhs_loc, result_reg, 8, &reg_manager);
                moveLocToReg(rhs_loc, temp_reg, 8, &reg_manager);
                const op = switch (self.insts[i]) {
                    .addd => "addsd",
                    .subd => "subsd",
                    .muld => "mulsd",
                    .divd => "divsd",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {f}, {f}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .eq, .lt, .gt => |bin_op| {
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                moveLocToReg(lhs_loc, reg, PTR_SIZE, &reg_manager);
                reg_manager.print("\tcmp {f}, {f}\n ", .{ reg, print(rhs_loc, .byte) });
                reg_manager.print("\tsete {f}\n", .{reg.lower8()});
                reg_manager.print("\tmovzx {f}, {f}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .eqf, .ltf, .gtf => |bin_op| {
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                moveLocToReg(lhs_loc, reg, 4, &reg_manager);
                reg_manager.print("\tcomiss {f}, {f}\n", .{ reg, print(rhs_loc, .dword) });

                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                reg_manager.print("\tsete {f}\n", .{res_reg.lower8()});
                reg_manager.print("\tmovzx {f}, {f}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .eqd, .ltd, .gtd => |bin_op| {
                const lhs_loc = reg_manager.consumeResult(bin_op.lhs);
                const reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = reg_manager.consumeResult(bin_op.rhs);
                moveLocToReg(lhs_loc, reg, 8, &reg_manager);
                reg_manager.print("\tcomisd {f}, {f}\n", .{ reg, print(rhs_loc, .qword) });

                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                reg_manager.print("\tsete {f}\n", .{res_reg.lower8()});
                reg_manager.print("\tmovzx {f}, {f}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .not => |rhs| {
                const rhs_loc = reg_manager.consumeResult(rhs);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                moveLocToReg(rhs_loc, reg, typeSize(TypePool.@"bool"), &reg_manager);
                reg_manager.print("\ttest {f}, {f}\n", .{reg, reg});
                reg_manager.print("\tsetz {f}\n", .{reg.lower8()});
                results[i] = ResultLocation {.reg = reg};
            },
            .i2d => {
                const loc = reg_manager.consumeResult(i - 1);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_int_reg, typeSize(TypePool.double), &reg_manager);
                reg_manager.print("\tcvtsi2sd {f}, {f}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2i => {

                // CVTPD2PI

                const loc = reg_manager.consumeResult(i - 1);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_float_reg, typeSize(TypePool.int), &reg_manager);
                reg_manager.print("\tcvtsd2si {f}, {f}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .i2f => {
                const loc = reg_manager.consumeResult(i - 1);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_int_reg, typeSize(TypePool.float), &reg_manager);
                reg_manager.print("\tcvtsi2ss {f}, {f}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = reg_manager.consumeResult(i - 1);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_float_reg, typeSize(TypePool.int), &reg_manager);
                reg_manager.print("\tcvtss2si {f}, {f}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2d => {
                const loc = reg_manager.consumeResult(i - 1);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_float_reg, typeSize(TypePool.float), &reg_manager);
                reg_manager.print("\tcvtss2sd {f}, {f}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2f => {
                const loc = reg_manager.consumeResult(i - 1);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                moveLocToReg(loc, temp_float_reg, typeSize(TypePool.double), &reg_manager);
                reg_manager.print("\tcvtsd2ss {f}, {f}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer label_ct.* += 1;
                const loc = reg_manager.consumeResult(if_start.expr);
                results[i] = ResultLocation{ .local_lable = label_ct.* };

                const jump = switch (self.insts[if_start.expr]) {
                    .eq, .eqf, .eqd => "jne",
                    .lt, .ltf, .ltd => "jae",
                    .gt, .gtf, .gtd => "jbe",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                        moveLocToReg(loc, temp_reg, typeSize(TypePool.bool), &reg_manager);
                        reg_manager.print("\tcmp {f}, 0\n", .{temp_reg});
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
                const loc = reg_manager.consumeResult(i - 1);
                if (loc == .addr_reg and loc.addr_reg.disp == 0 and loc.addr_reg.mul == null) {
                    results[i] = ResultLocation {.reg = loc.addr_reg.reg };
                } else {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                    Details.moveAddrToReg(loc.addr_reg, reg, &reg_manager);
                    results[i] = ResultLocation {.reg = reg};

                }
            },
            .deref => {
                const loc = reg_manager.consumeResult(i - 1);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                moveLocToReg(loc, reg, PTR_SIZE, &reg_manager);

                results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
            },
            .field => |field| {
                switch (TypePool.lookup(field.t)) {
                    inline .tuple, .named => |tuple| results[i] = ResultLocation {.int_lit = @intCast(Sizes.tupleOffset(tuple.els, field.off))},
                    else => unreachable
                }
            },
            .getelementptr => |getelementptr| {
                const base = Details.moveLocToGpReg(reg_manager.consumeResult(getelementptr.base), PTR_SIZE, i, &reg_manager);
                // both the instruction responsible for `mul_imm` and `disp` should produce a int_lit
                const disp = if (getelementptr.disp) |disp| reg_manager.consumeResult(disp).int_lit else 0;
                if (getelementptr.mul) |mul| {
                    const mul_imm = reg_manager.consumeResult(mul.imm).int_lit;
                    const mul_reg = Details.moveLocToGpReg(reg_manager.consumeResult(mul.reg), PTR_SIZE, i, &reg_manager);
                    if (Word.fromSize(@intCast(mul_imm))) |word| {
                        results[i] = ResultLocation {.addr_reg = 
                            .{
                                .reg = base, 
                                .disp = disp, 
                                .mul = .{mul_reg, word}, 
                            }
                        };
                    } else {
                        reg_manager.print("\timul {f}, {f}, {}\n", .{mul_reg, mul_reg, mul_imm});
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
                _ = reg_manager.consumeResult(i - 1);
                results[i] = ResultLocation {.int_lit = @intCast(TypePool.lookup(t).array.size)};
            },
            .array_init => |array_init| {
                blk: switch (array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
                        const reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;
                        moveLocToReg(results[ptr], reg, PTR_SIZE, &reg_manager);
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
                results[i] = Details.offsetLoc(results[array_init_loc.array_init], array_init_loc.off, array_init.t);
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
                const res_loc = Details.offsetLoc(results[array_init_assign.array_init], array_init_assign.off, t);
                const loc = reg_manager.consumeResult(i - 1);
                switch (res_loc) {
                    .addr_reg => |addr_reg| moveLocToAddrReg(loc, addr_reg, sub_size, &reg_manager),
                    else => unreachable
                }
            },
            .array_init_end => |array_init| {
                blk: switch (self.insts[array_init].array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
                        _ = reg_manager.consumeResult(array_init);
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

 const builtinTextStart =
    \\.intel_syntax noprefix
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

const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";
