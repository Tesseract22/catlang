const std = @import("std");
const Io = std.Io;
const TypePool = @import("../type.zig");
const Cir = @import("../cir.zig");
const Index = Cir.Index;
const log = @import("../log.zig");
const InternPool = @import("../intern_pool.zig");
const Symbol = InternPool.Symbol;
const Lexer = @import("../lexer.zig");
const TypeCheck = @import("../typecheck.zig");
const Arch = @import("../arch.zig");
const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;

const assert = std.debug.assert;

const PTR_SIZE = 8;
const STACK_ALIGNMENT = 16;
const Opts = Arch.RegisterOptions(Register) {
    .gp_regs = GpRegs,
    .fp_regs = FloatRegs,
    .ptr_size = PTR_SIZE,
    .stack_alignment = STACK_ALIGNMENT,
};

const word_table = std.EnumArray(Arch.Word, []const u8).init(.{
    .one = "byte", .two = "hword", .four = "word", .eight = "dword",
});


fn offsetStackTop(writer: *std.Io.Writer, offset: isize) void {
    writer.print("\tadd sp, sp, {}\n", .{offset}) catch unreachable;
}

fn storeRegAddr(writer: *std.Io.Writer, addr: AddrReg, word: Word, src: Register) void {
    const str = selectStore(word);
    writer.print("\t{s} {s}, {f}\n", .{ str, src.adaptSize(word), print(addr, word) }) catch unreachable;
}

fn loadRegAddr(writer: *std.Io.Writer, addr: AddrReg, word: Word, dst: Register) void {
    const ldr = selectLoad(word);
    writer.print("\t{s} {s}, {f}\n", .{ ldr, dst.adaptSize(word), print(addr, word) }) catch unreachable;
}

fn printAddrReg(writer: *std.Io.Writer, addr: AddrReg, word: Word) void {
    assert(addr.mul == null);
    _ = word;
    writer.print("[{f}, {}]", .{ addr.reg, addr.disp }) catch unreachable;
}

fn printDataLoc(writer: *std.Io.Writer, idx: usize, prefix: []const u8) void {
    writer.print(".{s}{}", .{ prefix, idx }) catch unreachable;
}

pub fn printLoc(writer: *std.Io.Writer, loc: ResultLocation, word: Word) void {
    switch (loc) {
        .reg => |reg| writer.print("{s}", .{reg.adaptSize(word)}) catch unreachable,
        .addr_reg => |addr| writer.print("{f}", .{print(addr, word)}) catch unreachable,
        .int_lit => |i| writer.print("#{}", .{i}) catch unreachable,
        .string_data => |s| printDataLoc(writer, s, "s"),
        .float_data => |f| printDataLoc(writer, f, "f"),
        .double_data => |d| printDataLoc(writer, d, "d"),
        .foreign => |foreign| writer.print("{s}[rip]", .{Lexer.lookup(foreign)}) catch unreachable,
        inline .local_lable, .array => @panic("TODO"),
        .uninit => unreachable,
    }
}

fn moveAddrToRegImpl(rm: *RegisterManager, addr: AddrReg, word: Word, dst: Register) void {
    _ = word;
    if (addr.mul) |_|
        unreachable
        //rm.print_ass("addr {f}, {f}, {f}, #{}\n", .{ dst, addr.reg, mul[0], @intFromBool(mul[1]) })
    else
        rm.print_ass("add {f}, {f}, #{}\n", .{ dst, addr.reg, addr.disp });
}

fn selectLoad(word: Word) []const u8 {
    return switch (word) {
        .one => "ldrb",
        .two => "ldrh",
        .four, .eight => "ldr",
    };
}

fn selectStore(word: Word) []const u8 {
    return switch (word) {
        .one => "strb",
        .two => "strh",
        .four, .eight => "str",
    };
}

fn selectMoveLocToReg(src: ResultLocation, dst: Register, size: usize) ?[]const u8 {
    if (src == .uninit) return null;
    //var mov: []const u8 = "mov";
    const word = Word.fromSize(size).?;
    const op = switch (src) {
        .reg => |src_reg| blk: {
            if (src_reg == dst) return null;
            if (src_reg.isFloat() or dst.isFloat()) break :blk "fmov" else break :blk "mov";
        },
        //inline .stack_base, .stack_top, .addr_reg => |_| {if (size != 8) mov = "movzx";},
        .addr_reg => selectLoad(word),
        .string_data => "adr",
        .int_lit, .foreign, .local_lable => "mov",
        .float_data, .double_data => "ldr",
        .array, .uninit => unreachable,
    };
    return op;
}

fn moveLocToRegImpl(rm: *RegisterManager, src: ResultLocation, dst: Register, size: usize) void {
    const mov = selectMoveLocToReg(src, dst, size) orelse return;
    const word = Word.fromSize(size).?;
    rm.print_ass("{s} {s}, {f}\n", .{ mov, dst.adaptSize(word), print(src, word) });
}

fn moveLocToAddrRegImpl(rm: *RegisterManager, src: ResultLocation, addr: AddrReg, word: Word) void {

    const op = selectStore(word);
    const temp_loc = switch (src) {
        inline .string_data, .float_data, .double_data, .addr_reg, .int_lit, .local_lable, .foreign => blk: {
            const temp_reg = rm.getUnused(null, RegisterManager.GpMask).?;
            moveLocToReg(src, temp_reg, @intFromEnum(word), rm);
            break :blk ResultLocation{ .reg = temp_reg };
        },
        .array => unreachable,
        else => src,
    };
    rm.print_ass("{s} {f}, {f}\n", .{ op, print(temp_loc, word),  print(addr, word) });
}

const Register = enum {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    xzr,

    // 128-bit floating-point registers
    //q0, q1, q2, q3, q4, q5, q6, q7,
    //q8, q9, q10, q11, q12, q13, q14, q15,
    //q16, q17, q18, q19, q20, q21, q22, q23,
    //q24, q25, q26, q27, q28, q29, q30, q31,
    // 64-bit floating-point registers
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    d10,
    d11,
    d12,
    d13,
    d14,
    d15,
    d16,
    d17,
    d18,
    d19,
    d20,
    d21,
    d22,
    d23,
    d24,
    d25,
    d26,
    d27,
    d28,
    d29,
    d30,
    d31,

    sp,
    pub const stack_base = .x29;
    pub const stack_top = .sp;
    pub const Lower32 = enum {
        w0,
        w1,
        w2,
        w3,
        w4,
        w5,
        w6,
        w7,
        w8,
        w9,
        w10,
        w11,
        w12,
        w13,
        w14,
        w15,
        w16,
        w17,
        w18,
        w19,
        w20,
        w21,
        w22,
        w23,
        w24,
        w25,
        w26,
        w27,
        w28,
        w29,
        w30,
        wzr,

        s0,
        s1,
        s2,
        s3,
        s4,
        s5,
        s6,
        s7,
        s8,
        s9,
        s10,
        s11,
        s12,
        s13,
        s14,
        s15,
        s16,
        s17,
        s18,
        s19,
        s20,
        s21,
        s22,
        s23,
        s24,
        s25,
        s26,
        s27,
        s28,
        s29,
        s30,
        s31,

        pub fn format(value: Lower32, writer: *std.Io.Writer) !void {
            _ = try writer.writeAll(@tagName(value));
        }
    };
    // only floating point register
    //pub const Lower16 = enum {
    //    h0, h1, h2, h3, h4, h5, h6, h7,
    //    h8, h9, h10, h11, h12, h13, h14, h15,
    //    h16, h17, h18, h19, h20, h21, h22, h23,
    //    h24, h25, h26, h27, h28, h29, h30, h31,
    //    pub fn format(value: Lower16, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    //        _ = try writer.writeAll(@tagName(value));
    //    }

    //};
    pub fn isFloat(self: Register) bool {
        return switch (@intFromEnum(self)) {
            @intFromEnum(Register.d0)...@intFromEnum(Register.d31) => true,
            else => false,
        };
    }
    pub fn lower32(self: Register) Lower32 {
        return @enumFromInt(@intFromEnum(self));
    }
    //pub fn lower16(self: Register) Lower32 {
    //    return @enumFromInt(@intFromEnum(self));
    //}
    pub fn adaptSize(self: Register, word: Word) []const u8 {
        return switch (word) {
            .one, .two, .four => @tagName(self.lower32()),
            .eight => @tagName(self),
        };
    }

    //pub const DivendReg = Register.rax;
    //pub const DivQuotient = Register.rax;
    //pub const DivRemainder = Register.rdx;

    pub fn format(value: Register, writer: *std.Io.Writer) !void {
        _ = try writer.writeAll(@tagName(value));
    }
};

const rm_table = Arch.RMTable(Register){
    .offset_stack_top = offsetStackTop,
    .store_reg_addr = storeRegAddr,
    .load_reg_addr = loadRegAddr,
};

const mov_table = Arch.MovTable(Register, Opts, rm_table){
    .mov_addr_to_reg = moveAddrToRegImpl,
    .mov_loc_to_reg = moveLocToRegImpl,
    .mov_loc_to_addr_reg = moveLocToAddrRegImpl,
};

const p_table = Arch.PrintTable(Register){
    .print_loc = printLoc,
    .print_addr_reg = printAddrReg,
};

const Details = Arch.ArchDetails(Register, Opts, rm_table, mov_table);

const Word = Arch.Word;
const GpRegs: []const Register = &.{
    .x0,  .x1,  .x2,  .x3,  .x4,  .x5,  .x6,  .x7,
    .x8,  .x9,  .x10, .x11, .x12, .x13, .x14, .x15,
    .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
    .x24, .x25, .x26, .x27, .x28, .x29, .x30, .xzr,
};
// This actually depends on the calling convention
const FloatRegs: []const Register = &.{
    .d0,  .d1,  .d2,  .d3,  .d4,  .d5,  .d6,  .d7,
    .d8,  .d9,  .d10, .d11, .d12, .d13, .d14, .d15,
    .d16, .d17, .d18, .d19, .d20, .d21, .d22, .d23,
    .d24, .d25, .d26, .d27, .d28, .d29, .d30, .d31,
};
const RegisterManager = Arch.RegisterManagerT(
    Register, Opts, rm_table);
const CallingConvention = RegisterManager.CallingConvention;
const ResultLocation = Arch.ResultLocationT(Register);
const AddrReg = Arch.AddrRegT(Register);
const print = Arch.Print(Register, p_table).print;
const alignAllocRaw = Arch.alignAllocRaw;

const Sizes = Arch.SizeFn(PTR_SIZE, STACK_ALIGNMENT);
const typeSize = Sizes.typeSize;
const alignOf = Sizes.alignOf;
const tupleOffset = Sizes.tupleOffset;

const moveLocToStackBase = Details.moveLocToStackBase;
const moveLocToAddrReg = Details.moveLocToAddrReg;
const moveLocToReg = Details.moveLocToReg;
const moveLocToGpReg = Details.moveLocToGpReg;
const moveLocToFloatReg = Details.moveLocToFloatReg;


pub fn roundUpMultipleOf(size: usize, alignment: usize) usize {
    return alignAllocRaw(size, 0, alignment);
}
pub fn alignStack(curr_size: usize) usize {
    return alignAllocRaw(curr_size, 0, STACK_ALIGNMENT);
}
pub fn consumeResult(results: []ResultLocation, idx: Index, reg_mangager: *RegisterManager) ResultLocation {
    const loc = results[idx.i()];
    switch (loc) {
        .reg => |reg| reg_mangager.markUnused(reg),
        .addr_reg,
        => |addr_reg| {
            reg_mangager.markUnused(addr_reg.reg);
            if (addr_reg.mul) |mul|
                reg_mangager.markUnused(mul[0]);
        },

        inline .float_data, .double_data, .string_data, .int_lit, .foreign, .local_lable, .array, .uninit => {},
    }
    return loc;
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
    pub const CallerSaveRegs = [_]Register{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15, .x16, .x17, .x18, .d0, .d1, .d2, .d3, .d4, .d5, .d6, .d7, .d16, .d17, .d18, .d19, .d20, .d21, .d22, .d23, .d24, .d25, .d26, .d27, .d28, .d29, .d30, .d31 };
    pub const CalleeSaveRegs = [_]Register{ .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28, .d8, .d9, .d10, .d11, .d12, .d13, .d14, .d15 };
    pub const CallerSaveMask = RegisterManager.cherryPick(&CallerSaveRegs);
    pub const CalleeSaveMask = RegisterManager.cherryPick(&CalleeSaveRegs);

    pub fn interface() CallingConvention {
        return .{ .vtable = .{ .call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog }, .callee_saved = CalleeSaveMask };
    }
    fn getFloatLoc(t_pos: u8) Register {
        return @enumFromInt(t_pos + @intFromEnum(Register.d0));
    }
    fn getIntLoc(t_pos: u8) Register {
        return @enumFromInt(t_pos + @intFromEnum(Register.x0));
    }
    fn classifyType(t: Type) Class {
        const t_full = TypePool.lookup(t);
        switch (t_full) {
            .number_lit, .void, .function, .type => unreachable,
            .float, .double => return .float,
            .ptr, .int, .bool, .char => return .int,
            .array => |array| {
                const base_class = classifyType(array.el);
                switch (base_class) {
                    .nfa => |nfa| {
                        if (nfa.count * array.size <= 4) return Class{ .nfa = .{ .base = nfa.base, .count = nfa.count * array.size } };
                    },
                    .float => {
                        if (array.size <= 4) return Class{ .nfa = .{ .base = array.el, .count = array.size } };
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
                return .{ .nfa = .{ .base = nfa_base.?, .count = nfa_count } };
            },
            .subset => |subset| return classifyType(subset.sub_t),
        }
    }

    pub fn prolog(self: Cir, rm: *RegisterManager, results: []ResultLocation) void {
        rm.markCleanAll();
        rm.markUnusedAll();

        // allocate return
        // Index 1 of insts is always the ret_decl

        if (self.ret_type != TypePool.void) {
            const ret_loc = findCallArgsLoc(&.{self.ret_type}, rm.gpa);
            defer ret_loc.deinit(rm.gpa);
            if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                results[Index.ret.i()] = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = 0 } };
                rm.markUsed(.x29, .ret);
            }
        }
        const args_loc = findCallArgsLoc(self.arg_types, rm.gpa);
        defer args_loc.deinit(rm.gpa);
        for (0..args_loc.locs.len) |arg_i| {
            const stack_pos = rm.allocateStack(args_loc.sizes[arg_i], args_loc.aligns[arg_i]);
            if (args_loc.turn_into_addr[arg_i]) |_| self.insts[2 + arg_i].arg_decl.auto_deref = true;
            switch (args_loc.locs[arg_i]) {
                .gp_regs => |reg_loc| {
                    for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                        const reg = getIntLoc(@intCast(r));
                        const loc = ResultLocation{ .reg = reg };
                        moveLocToStackBase(loc, stack_pos + PTR_SIZE * @as(isize, @intCast(r - reg_loc.start)), PTR_SIZE, rm);
                    }
                    results[2 + arg_i] = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = stack_pos } };
                },
                .vf_regs => |reg_loc| {
                    for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                        const reg = getFloatLoc(@intCast(r));
                        const loc = ResultLocation{ .reg = reg };
                        moveLocToStackBase(loc, stack_pos + PTR_SIZE * @as(isize, @intCast(r - reg_loc.start)), PTR_SIZE, rm);
                    }
                    results[2 + arg_i] = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = stack_pos } };
                },
                .stack => |off| {
                    results[2 + arg_i] = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = off + 2 * PTR_SIZE } };
                },
            }
        }
    }
    pub fn epilog(reg_manager: *RegisterManager, results: []ResultLocation, ret_t: Type, i: Index) void {
        if (ret_t != TypePool.void) {
            const ret_loc = findCallArgsLoc(&.{ret_t}, reg_manager.gpa);
            defer ret_loc.deinit(reg_manager.gpa);

            const loc = consumeResult(results, i.prev(), reg_manager);
            if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                // FIXME: We needs to stored the value of x8 in prolog, because calling another function could potentatially pollutes the value of x8
                moveLocToAddrReg(loc, AddrReg{ .reg = .x8, .disp = 0 }, typeSize(ret_t), reg_manager);
            } else {
                switch (ret_loc.locs[0]) {
                    .gp_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                            const reg = getIntLoc(@intCast(r));
                            moveLocToReg(loc.offsetByByte(PTR_SIZE * @as(isize, @intCast(r - reg_loc.start))), reg, PTR_SIZE, reg_manager);
                        }
                    },
                    .vf_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                            const reg = getFloatLoc(@intCast(r));
                            moveLocToReg(loc.offsetByByte(PTR_SIZE * @as(isize, @intCast(r - reg_loc.start))), reg, PTR_SIZE, reg_manager);
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
        reg_manager.print("\tldp x29, x30, [sp], 16\n", .{});
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

            moveLocToReg(.{ .reg = reg }, dest_reg, 8, reg_manager);
            results[inst.i()] = switch (results[inst.i()]) {
                .reg => ResultLocation{ .reg = dest_reg },
                .addr_reg => |old_addr| blk: {
                    break :blk if (old_addr.reg == reg)
                        ResultLocation{ .addr_reg = AddrReg{ .mul = old_addr.mul, .reg = dest_reg, .disp = old_addr.disp } }
                    else
                        ResultLocation{ .addr_reg = AddrReg{ .mul = .{ dest_reg, old_addr.mul.?[1] }, .reg = old_addr.reg, .disp = old_addr.disp } };
                    },
                    else => unreachable,
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
                else => {
                    args.turn_into_addr[arg_i] = null;
                },
            }
            // B.6 - ignored
            if (alignment.* <= PTR_SIZE) alignment.* = PTR_SIZE;
            if (alignment.* >= PTR_SIZE * 2) alignment.* = 2 * PTR_SIZE;
            // Stage B ends
            // Stage C - Assignment of arguments to registers and stack
            //const arg_loc = consumeResult(results, arg.i, reg_manager);
            // C.1 - Assign float to v[NSRN] if NSRN < 8
            if (class == .float and NSRN < 8) {
                args.locs[arg_i] = .{ .vf_regs = .{ .start = @intCast(NSRN), .count = 1 } };
                NSRN += 1;
                continue;
            }
            if (class == .nfa and NSRN + class.nfa.count <= 8) { // C.2 - Assign NFA,NVA to v[NSRN]
                args.locs[arg_i] = .{ .vf_regs = .{ .start = @intCast(NSRN), .count = @intCast(class.nfa.count) } };
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
                args.locs[arg_i] = .{ .gp_regs = .{ .start = @intCast(NGRN), .count = 1 } };
                NGRN += 1;
                continue;
            }
            if (alignment.* == 2 * PTR_SIZE) { // C.10
                NGRN = roundUpMultipleOf(NGRN, 2);
            }
            // C.11 - ignored, all integer sizes <= PTR_SIZE in our language
            if (class.isComposite() and size.* / PTR_SIZE <= 8 - NGRN) { // C.12 - Composite type
                args.locs[arg_i] = .{ .gp_regs = .{ .start = @intCast(NGRN), .count = @intCast(size.* / PTR_SIZE) } };
                NGRN += size.* / PTR_SIZE;
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
                NSAA = alignAllocRaw(NSAA, typeSize(t), @max(PTR_SIZE, alignOf(t)));
            }
        }
        args.NSAA = NSAA;
        return args;
    }
    // aarch64 procedure call standard
    // https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
    pub fn makeCall(i: Index, call: Cir.Inst.Call, reg_manager: *RegisterManager, results: []ResultLocation) void {
        const result = &results[i.i()];
        saveVolatile(reg_manager, results);

        if (call.t != TypePool.void) {
            const ret_loc = findCallArgsLoc(&.{call.t}, reg_manager.gpa);
            defer ret_loc.deinit(reg_manager.gpa);
            if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                const stack_off = reg_manager.allocateStackTyped(call.t);
                reg_manager.print("\tadd x8, x29, {}\n", .{stack_off});
            }
        }
        const args_loc = findCallArgsLoc(call.ts, reg_manager.gpa);
        defer args_loc.deinit(reg_manager.gpa);
        _ = reg_manager.allocateStackTemp(args_loc.NSAA, STACK_ALIGNMENT);
        defer reg_manager.freeStackTemp();
        for (call.locs, call.ts, 0..) |loc_i, t, arg_i| {
            var loc = consumeResult(results, loc_i, reg_manager);
            const raw_size = typeSize(t);
            if (args_loc.turn_into_addr[arg_i]) |addr| {
                moveLocToAddrReg(loc, AddrReg{ .reg = .sp, .disp = @intCast(addr) }, raw_size, reg_manager);
                const addr_reg = reg_manager.getUnused(null, RegisterManager.GpMask).?;
                reg_manager.print("\tadd {f}, sp, {}\n", .{ addr_reg, addr });
                loc = ResultLocation{ .reg = addr_reg };
            }
            switch (args_loc.locs[arg_i]) {
                .gp_regs => |reg_loc| {
                    for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                        const reg = getIntLoc(@intCast(r));
                        moveLocToReg(loc.offsetByByte(PTR_SIZE * @as(isize, @intCast(r - reg_loc.start))), reg, PTR_SIZE, reg_manager);
                    }
                },
                .vf_regs => |reg_loc| {
                    for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                        const reg = getFloatLoc(@intCast(r));
                        moveLocToReg(loc.offsetByByte(PTR_SIZE * @as(isize, @intCast(r - reg_loc.start))), reg, PTR_SIZE, reg_manager);
                    }
                },
                .stack => |off| {
                    moveLocToAddrReg(loc, AddrReg{ .reg = .sp, .disp = off }, raw_size, reg_manager);
                },
            }
        }
        const func_res = consumeResult(results, call.func, reg_manager);
        switch (func_res) {
            .foreign => |foreign| {
                reg_manager.print("\tbl {s}\n", .{Lexer.lookup(foreign)});
            },
            else => {
                const reg = reg_manager.getUnused(null, CalleeSaveMask).?;
                moveLocToReg(func_res,  reg, PTR_SIZE, reg_manager);
                reg_manager.print("\tbl {f}\n", .{reg});
            },
        }
        if (call.t != TypePool.void) {
            const ret_loc = findCallArgsLoc(&.{call.t}, reg_manager.gpa);
            defer ret_loc.deinit(reg_manager.gpa);
            if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                result.* = ResultLocation{ .addr_reg = .{ .reg = .x8, .disp = 0 } };
                reg_manager.markUsed(.x8, i);
            } else {
                switch (ret_loc.locs[0]) {
                    .gp_regs => |reg_loc| {
                        const stack_off = reg_manager.allocateStackTyped(call.t);
                        if (reg_loc.count > 1) {
                            for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                                const reg = ResultLocation{ .reg = getIntLoc(@intCast(r)) };
                                moveLocToAddrReg(reg, AddrReg{ .reg = .x29, .disp = stack_off + @as(isize, @intCast(r)) * PTR_SIZE }, PTR_SIZE, reg_manager);
                            }
                            result.* = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = stack_off } };
                        } else {
                            const reg = getIntLoc(0);
                            result.* = ResultLocation{ .reg = reg };
                            reg_manager.markUsed(reg, i);
                        }
                    },
                    .vf_regs => |reg_loc| {
                        const stack_off = reg_manager.allocateStackTyped(call.t);
                        if (reg_loc.count > 1) {
                            for (reg_loc.start..reg_loc.start + reg_loc.count) |r| {
                                const reg = ResultLocation{ .reg = getFloatLoc(@intCast(r)) };
                                moveLocToAddrReg(reg, AddrReg{ .reg = .x29, .disp = stack_off + @as(isize, @intCast(r)) * PTR_SIZE }, PTR_SIZE, reg_manager);
                            }
                            result.* = ResultLocation{ .addr_reg = .{ .reg = .x29, .disp = stack_off } };
                        } else {
                            const reg = getFloatLoc(0);
                            result.* = ResultLocation{ .reg = reg };
                            reg_manager.markUsed(reg, i);
                        }
                    },
                    else => unreachable,
                }
            }
        }
    }
};
pub const OutputBuffer = std.ArrayList(u8);
pub fn compileAll(cirs: []Cir, file: *Io.Writer, gpa: std.mem.Allocator, os: std.Target.Os.Tag) Arch.CompileError!void {
    try file.print("{s}", .{switch (os) {
        .linux => builtinTextStart,
        .windows => builtinTextWinMain,
        else => unreachable,
    }});

    // Static Data needed by the program
    var string_data = std.array_hash_map.Auto(Symbol, usize).empty;
    var double_data = std.array_hash_map.Auto(u64, usize).empty;
    var float_data = std.array_hash_map.Auto(u32, usize).empty;
    defer {
        string_data.deinit(gpa);
        double_data.deinit(gpa);
        float_data.deinit(gpa);
    }

    var label_ct: usize = 0;

    const cconv = switch (os) {
        .linux => CDecl.interface(),
        //.windows => CallingConvention.FastCall.interface(),
        else => @panic("Unsupported OS, only linux and windows is supported"),
    };
    // This creates the entry point of the program
    {
        var entry_insts = [_]Cir.Inst{
            Cir.Inst{ .block_start = {} },
            Cir.Inst{ .ret_decl = TypePool.void },
            Cir.Inst{ .foreign = .{ .sym = Lexer.main,  } },
            Cir.Inst{ .call = .{ .func = @enumFromInt(2), .t = TypePool.void, .locs = &.{}, .ts = &.{}, .varadic = false, .discard = true, } },
            Cir.Inst{ .lit = .{ .int = 93 } },
            Cir.Inst{ .lit = .{ .int = 0 } },
            Cir.Inst{ .foreign = .{ .sym = Lexer.intern("syscall1"), } },
            Cir.Inst{ .call = .{ .func = @enumFromInt(6), .t = TypePool.void, .ts = &.{TypePool.int, TypePool.int}, .locs = &.{@enumFromInt(4), @enumFromInt(5)}, .varadic = false, .discard = true } },
            Cir.Inst{ .block_end = .start },
        };
        const entry = switch (os) {
            .linux => "_start",
            .windows => "WinMain",
            else => unreachable,
        };
        const pgm_entry = Cir{ .arg_types = &.{}, .insts = &entry_insts, .name = Lexer.intern(entry), .ret_type = TypePool.void };
        // On windows, the start function requires an additional 8 byte of the stack
        // On linux, it doesn't
        const prologue = switch (os) {
            .linux => false,
            .windows => true,
            else => unreachable,
        };
        try compile(pgm_entry, file, &string_data, &double_data, &float_data, &label_ct, cconv, gpa, prologue);
    }
    for (cirs) |cir| {
        try compile(cir, file, &string_data, &double_data, &float_data, &label_ct, cconv, gpa, true);
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
    try file.flush();
}
pub fn compile(self: Cir, file: *std.Io.Writer, string_data: *std.array_hash_map.Auto(Symbol, usize), double_data: *std.array_hash_map.Auto(u64, usize), float_data: *std.array_hash_map.Auto(u32, usize), label_ct: *usize, cconv: CallingConvention, gpa: std.mem.Allocator, prologue: bool) Arch.CompileError!void {
    log.debug ("\nfunction: {s}\n", .{ Lexer.string_pool.lookup(self.name) });
    var function_body_buffer = std.Io.Writer.Allocating.init(gpa);

    const body_writer = &function_body_buffer.writer;

    const results = gpa.alloc(ResultLocation, self.insts.len) catch unreachable;
    defer gpa.free(results);

    var reg_manager = RegisterManager.init(cconv, body_writer, gpa, results);
    defer {
        if (reg_manager.temp_stack.items.len != 0) {
            @panic("not all tempory stack is free");
        }

        file.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)}) catch unreachable;
        if (prologue) {
            file.print("\tstp x29, x30, [sp, -16]!\n", .{}) catch unreachable;
            file.print("\tmov x29, sp\n", .{}) catch unreachable;
            file.print("\tsub sp, sp, {}\n", .{reg_manager.max_usage}) catch unreachable;
        }

        file.writeAll(function_body_buffer.written()) catch unreachable;
        function_body_buffer.deinit();
        reg_manager.deinit();
    }
    for (self.insts, results, 0..) |*inst, *result, index| {
        const i: Index = @enumFromInt(index);
        reg_manager.debug();
        log.debug("{f} {f}", .{ i, inst.* });
        reg_manager.print("# {f} {f}\n", .{ i, inst });
        switch (inst.*) {
            .ret => |ret| {
                cconv.epilog(&reg_manager, results, ret.t, i);
            },
            .lit => |lit| {
                switch (lit) {
                    .int => |int| result.* = ResultLocation{ .int_lit = int },
                    .string => |s| {
                        const kv = string_data.getOrPutValue(gpa, s, string_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else string_data.count() - 1;
                        result.* = ResultLocation{ .string_data = idx };
                    },
                    .double => |f| {
                        const kv = double_data.getOrPutValue(gpa, @bitCast(f), double_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else double_data.count() - 1;
                        result.* = ResultLocation{ .double_data = idx };
                    },
                    .float => |f| {
                        const kv = float_data.getOrPutValue(gpa, @bitCast(f), float_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else float_data.count() - 1;
                        result.* = ResultLocation{ .float_data = idx };
                    },
                    .bool => unreachable,
                }
            },
            .var_decl => |var_decl| {
                // TODO explicit operand position
                // const size = typeSize(var_decl);

                // var loc = consumeResult(results, i - 1, &reg_manager);
                // try loc.moveToStackBase(scope_size, size, &reg_manager, results);
                result.* = ResultLocation.stackBase(reg_manager.allocateStackTyped(var_decl.t));
                // reg_manager.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const v = switch (self.insts[var_access.i()]) {
                    .arg_decl, .var_decl => |v| v,
                    else => unreachable,
                };
                const loc = results[var_access.i()];
                if (v.auto_deref) {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                    moveLocToReg(loc,  reg, PTR_SIZE, &reg_manager);
                    result.* = ResultLocation{ .addr_reg = .{ .reg = reg, .disp = 0 } };
                } else {
                    result.* = loc;
                }
            },
            .var_assign => |var_assign| {
                const var_loc = results[var_assign.lhs.i()];
                const expr_loc = results[var_assign.rhs.i()];
                //log.note("expr_loc {}", .{expr_loc});
                switch (var_loc) {
                    .addr_reg => |reg| moveLocToAddrReg(expr_loc, reg, typeSize(var_assign.t), &reg_manager),
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
                result.* = ResultLocation{ .foreign = foreign.sym };
            },
            .call => |call| {
                cconv.makeCall(i, call, &reg_manager, results);
            },
            .add,
            .sub,
            .mul,
            .div,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const lhs_reg = moveLocToGpReg(lhs_loc, PTR_SIZE, i, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = moveLocToGpReg(rhs_loc, PTR_SIZE, null, &reg_manager);

                const op = switch (inst.*) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "sdiv",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {f}, {f}, {f}\n", .{ op, lhs_reg, lhs_reg, rhs_reg });

                result.* = ResultLocation{ .reg = lhs_reg };
            },
            .mod => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);

                const lhs_reg = moveLocToGpReg(lhs_loc, PTR_SIZE, i, &reg_manager);
                const rhs_reg = moveLocToGpReg(rhs_loc, PTR_SIZE, i, &reg_manager);
                defer { reg_manager.markUnused(lhs_reg); reg_manager.markUnused(rhs_reg); }

                const quotient_reg = reg_manager.getUnused(null, RegisterManager.GpMask).?;
                reg_manager.print("\tsdiv {f}, {f}, {f}\n", .{ quotient_reg, lhs_reg, rhs_reg });
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;
                reg_manager.print("\tmsub {f}, {f}, {f}, {f}\n", .{ res_reg, quotient_reg, rhs_reg, lhs_reg });
                result.* = ResultLocation{ .reg = res_reg };
            },
            .addf,
            .subf,
            .mulf,
            .divf,
            .addd,
            .subd,
            .muld,
            .divd,
            => |bin_op| {
                const size: usize = switch (inst.*) {
                    .addf, .subf, .mulf, .divf => 4,
                    .addd, .subd, .muld, .divd => 8,
                    else => unreachable,
                };
                const word = Word.fromSize(size).?;
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask).?;
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask).?;

                moveLocToReg(lhs_loc,  result_reg, size, &reg_manager);
                moveLocToReg(rhs_loc,  temp_reg, size, &reg_manager);
                const op = switch (inst.*) {
                    .addf, .addd => "fadd",
                    .subf, .subd => "fsub",
                    .mulf, .muld => "fmul",
                    .divf, .divd => "fdiv",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {s}, {s}, {s}\n", .{ op, result_reg.adaptSize(word), result_reg.adaptSize(word), temp_reg.adaptSize(word) });
                result.* = ResultLocation{ .reg = result_reg };
            },
            .eq, .lt, .gt => |bin_op| {
                const size = typeSize(bin_op.t);
                const word = Word.fromSize(size).?;

                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = moveLocToGpReg(lhs_loc, size, i, &reg_manager);
                const rhs_reg = moveLocToGpReg(rhs_loc, size, null, &reg_manager);
                
                reg_manager.print("\tcmp {s}, {s}\n", .{ lhs_reg.adaptSize(word), rhs_reg.adaptSize(word) });
                reg_manager.print("\tcset {f}, {s}\n", .{ lhs_reg, @tagName(inst.*)[0..2] });
                result.* = ResultLocation{ .reg = lhs_reg };
            },
            .eqf, .ltf, .gtf, .eqd, .ltd, .gtd => |bin_op| {
                const size: usize = switch (inst.*) {
                    .eqf, .ltf, .gtf => 4,
                    .eqd, .ltd, .gtd => 8,
                    else => unreachable,
                };
                const word = Word.fromSize(size).?;
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = moveLocToFloatReg(lhs_loc, size, i, &reg_manager);
                const rhs_reg = moveLocToFloatReg(rhs_loc, size, null, &reg_manager);
                reg_manager.print("\tfcmp {s}, {s}\n", .{ lhs_reg.adaptSize(word), rhs_reg.adaptSize(word) });
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;
                reg_manager.print("\tcset {f}, {s}\n", .{ res_reg, @tagName(inst.*)[0..2] });
                result.* = ResultLocation{ .reg = res_reg };
                reg_manager.markUnused(lhs_reg);
            },
            .not => |rhs| {
                const rhs_loc = consumeResult(results, rhs, &reg_manager);
                const reg = moveLocToGpReg(rhs_loc, typeSize(TypePool.bool), i, &reg_manager);
                reg_manager.print("\teor {f}, {f}, #1\n", .{ reg, reg });
                result.* = ResultLocation{ .reg = reg };
            },
            .i2d, .i2f => {
                const size: usize = if (inst.* == .i2d) 8 else 4;
                const loc = consumeResult(results, i.prev(), &reg_manager);
                const temp_int_reg = moveLocToGpReg(loc, PTR_SIZE, null, &reg_manager);
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask).?;
                reg_manager.print("\tscvtf {s}, {f}\n", .{ res_reg.adaptSize(Word.fromSize(size).?), temp_int_reg });
                result.* = ResultLocation{ .reg = res_reg };
            },
            .d2i, .f2i => {
                const size: usize = if (inst.* == .d2i) 8 else 4;
                const loc = consumeResult(results, i.prev(), &reg_manager);
                const temp_float_reg = moveLocToFloatReg(loc, size, null, &reg_manager);
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;

                const word = Word.fromSize(size).?;
                reg_manager.print("\tfcvtzs {s}, {s}\n", .{ res_reg.adaptSize(word), temp_float_reg.adaptSize(word) });
                result.* = ResultLocation{ .reg = res_reg };
            },
            .f2d, .d2f => {
                const from_size: usize, const to_size: usize = if (inst.* == .f2d) .{ 4, 8 } else .{ 8, 4 };
                const loc = consumeResult(results, i.prev(), &reg_manager);
                const temp_float_reg = moveLocToFloatReg(loc, from_size, null, &reg_manager);
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask).?;
                reg_manager.print("\tfcvt {s}, {s}\n", .{ res_reg.adaptSize(Word.fromSize(to_size).?), temp_float_reg.adaptSize(Word.fromSize(from_size).?) });
                result.* = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer label_ct.* += 1;
                const loc = consumeResult(results, if_start.expr, &reg_manager);
                result.* = ResultLocation{ .local_lable = label_ct.* };

                const jump = switch (self.insts[if_start.expr.i()]) {
                    .eq, .eqf, .eqd => "bne",
                    .lt, .ltf, .ltd => "bge",
                    .gt, .gtf, .gtd => "ble",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                        moveLocToReg(loc,  temp_reg, typeSize(TypePool.bool), &reg_manager);
                        reg_manager.print("\tcmp {f}, 0\n", .{temp_reg});
                        break :blk "beq";
                    },
                };
                reg_manager.print("\t{s} .L{}\n", .{ jump, label_ct.* });
            },
            .else_start => |if_start| {
                reg_manager.print("\tb .LE{}\n", .{results[self.insts[if_start.i()].if_start.first_if.i()].local_lable});
                reg_manager.print(".L{}:\n", .{results[if_start.i()].local_lable});
            },
            .if_end => |start| {
                const label = results[start.i()].local_lable;
                reg_manager.print(".LE{}:\n", .{label});
            },
            .while_start => {
                defer label_ct.* += 1;
                result.* = ResultLocation{ .local_lable = label_ct.* };

                reg_manager.print(".W{}:\n", .{label_ct.*});
            },
            .while_jmp => |while_start| {
                const label = results[while_start.i()].local_lable;
                reg_manager.print("\tb .W{}\n", .{label});
            },
            .block_start => {
                reg_manager.enterScope();
            },
            .block_end => |start| {
                _ = start;
                reg_manager.exitScope();
            },
            .addr_of => {
                // FIXME: the whole `consumeResults` mechanic is rigged...
                const loc = consumeResult(results, i.prev(), &reg_manager);
                if (loc == .addr_reg and loc.addr_reg.disp == 0 and loc.addr_reg.mul == null) {
                    result.* = ResultLocation{ .reg = loc.addr_reg.reg };
                } else {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                    Details.moveAddrToReg(loc.addr_reg, reg, &reg_manager);
                    result.* = ResultLocation{ .reg = reg };
                }
            },
            .deref => {
                const loc = consumeResult(results, i.prev(), &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                moveLocToReg(loc,  reg, PTR_SIZE, &reg_manager);

                result.* = ResultLocation{ .addr_reg = .{ .reg = reg, .disp = 0 } };
            },
            .field => |field| {
                switch (TypePool.lookup(field.t)) {
                    inline .tuple, .named => |tuple| result.* = ResultLocation{ .int_lit = @intCast(tupleOffset(tuple.els, field.off)) },
                    else => unreachable,
                }
            },
            .getelementptr => |getelementptr| {
                const base = moveLocToGpReg(consumeResult(results, getelementptr.base, &reg_manager), PTR_SIZE, i, &reg_manager);
                // both the instruction responsible for `mul_imm` and `disp` should produce a int_lit
                const disp = if (getelementptr.disp) |disp| consumeResult(results, disp, &reg_manager).int_lit else 0;
                if (getelementptr.mul) |mul| {
                    const mul_imm = moveLocToGpReg(consumeResult(results, mul.imm, &reg_manager), PTR_SIZE, i, &reg_manager);
                    const mul_reg = moveLocToGpReg(consumeResult(results, mul.reg, &reg_manager), PTR_SIZE, null, &reg_manager);
                    reg_manager.print("\tmul {f}, {f}, {f}\n", .{ mul_reg, mul_reg, mul_imm });
                    reg_manager.print("\tadd {f}, {f}, {f}\n", .{ base, base, mul_reg });
                    reg_manager.markUnused(mul_imm);
                    reg_manager.markUnused(mul_reg);
                    result.* = ResultLocation{ .addr_reg = .{
                        .reg = base,
                        .mul = null,
                        .disp = disp,
                    } };
                } else {
                    result.* = ResultLocation{ .addr_reg = .{
                        .reg = base,
                        .mul = null,
                        .disp = disp,
                    } };
                }
            },
            .type_size => |t| {
                result.* = ResultLocation{ .int_lit = @intCast(typeSize(t)) };
            },
            .array_len => |t| {
                _ = consumeResult(results, i.prev(), &reg_manager);
                result.* = ResultLocation{ .int_lit = @intCast(TypePool.lookup(t).array.size) };
            },
            .array_init => |array_init| {
                blk: switch (array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr.i()] == .uninit) {
                            continue :blk .self;
                        }
                        continue :blk .self;
                        //const reg = moveLocToGpReg(results[ptr.i()], PTR_SIZE, i, &reg_manager);
                        //result.* = ResultLocation { .addr_reg = .{.reg = reg, .disp = 0 } };
                    },
                    .loc => |loc| result.* = results[loc.i()],
                    .self => {
                        const stack_pos = reg_manager.allocateStackTyped(array_init.t);
                        result.* = ResultLocation.stackBase(stack_pos);
                    },
                    .none => unreachable,
                }
            },
            .array_init_loc => |array_init_loc| {
                const array_init = self.insts[array_init_loc.array_init.i()].array_init;
                result.* = Details.offsetLoc(results[array_init_loc.array_init.i()], array_init_loc.off, array_init.t);
            },
            .array_init_assign => |array_init_assign| {
                const array_init = self.insts[array_init_assign.array_init.i()].array_init;
                const t = array_init.t;
                const sub_t = switch (TypePool.lookup(t)) {
                    inline .tuple, .named => |tuple| tuple.els[array_init_assign.off],
                    .array => |array| array.el,
                    else => unreachable,
                };
                const sub_size = typeSize(sub_t);
                const res_loc = Details.offsetLoc(results[array_init_assign.array_init.i()], array_init_assign.off, t);
                const loc = consumeResult(results, i.prev(), &reg_manager);
                switch (res_loc) {
                    .addr_reg => |addr_reg| moveLocToAddrReg(loc, addr_reg, sub_size, &reg_manager),
                    else => unreachable,
                }
            },
            .array_init_end => |array_init| {
                //blk: switch (self.insts[array_init].array_init.res_inst) {
                //    .ptr => |ptr| {
                //        if (results[ptr] == .uninit) {
                //            continue :blk .none;
                //        }
                //        _ = consumeResult(results, array_init, &reg_manager);
                //        result.* = .uninit;
                //    },
                //    .loc => {
                //        result.* = .uninit;
                //    },
                //    .none => {
                //        result.* = results[array_init];
                //    },
                //}
                result.* = results[array_init.i()];
            },
            .uninit => result.* = .uninit,
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
    \\syscall1:
    \\mov x8, x0
    \\mov x0, x1
    \\svc #0
    \\ret
    \\
    \\syscall2:
    \\mov x8, x0          // syscall number
    \\mov x0, x1          // arg1
    \\mov x1, x2          // arg2
    \\svc #0
    \\ret
    \\syscall3:
    \\mov x8, x0
    \\mov x0, x1
    \\mov x1, x2
    \\mov x2, x3
    \\svc #0
    \\ret
    \\
;
const builtinTextWinMain =
    \\.intel_syntax noprefix
    \\.text
    \\.globl         WinMain
    \\
;

const fnStart = "\tpush x29\n\tmov x29, rsp\n";
