const std = @import("std");
const Cir = @import("cir.zig");
const x86_64 = @import("arch/x86-64.zig");
const arm64 = @import("arch/arm64.zig");
const log = @import("log.zig");
const Self = @This();
pub const CompileError = std.ArrayList(u8).Writer.Error || std.Io.Writer.Error;
compileAll: *const fn (cirs: []Cir, file: *std.Io.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) CompileError!void,


const ResolveArchError = error {
    Unsupported
};
pub fn resolve(target: std.Target) ResolveArchError!Self {
    return .{.compileAll = switch (target.cpu.arch) {
        .x86_64 => x86_64.compileAll,
        .aarch64 => arm64.compileAll,
        else => {
            log.err("CPU Arch `{}` is not supported", .{target.cpu.arch});
            return ResolveArchError.Unsupported;
        },
    }};
}


const Allocator = std.mem.Allocator;
const TypePool = @import("type.zig");
const InternPool = @import("intern_pool.zig");
const Symbol = InternPool.Symbol;
const Lexer = @import("lexer.zig");
const TypeCheck = @import("typecheck.zig");
const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;

pub const Word = enum(u8) {
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

pub const ResultLocationTag = enum(u32) {
    reg,
    addr_reg,
    int_lit,
    foreign,
    string_data,
    float_data,
    double_data,
    local_lable,
    array,
    uninit,
};

pub fn alignAllocRaw(curr_size: usize, size: usize, alignment: usize) usize {
    return (curr_size + size + (alignment - 1)) / alignment * alignment;
}

pub fn PrintAddrRegFn(comptime Register: type) type {
    return fn (writer: *std.Io.Writer, reg: Register, mul: ?struct { Register, Word }, disp: isize, word: Word) void;
}

pub fn AddrRegT(comptime Register: type) type {
    return struct {
        const Self = @This();
        reg: Register,
        mul: ?struct { Register, Word } = null,
        disp: isize,
    };
}

pub fn SizeFn(comptime PTR_SIZE: comptime_int, comptime STACK_ALIGNMENT: comptime_int) type {
    return struct {
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
            return alignAllocRaw(curr_size, size, alignment);
        }

        pub fn alignStack(curr_size: usize) usize {
            return alignAllocRaw(curr_size, 0, STACK_ALIGNMENT);
        }

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
                else => unreachable,
            };
        }

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

        pub fn getFrameSize(self: Cir, block_start: usize, curr_idx: *usize) usize {
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
                            .array, .tuple => size = alignAllocRaw(size, PTR_SIZE, PTR_SIZE),
                            else => {},
                        }
                    },
                    else => {},
                }
            }
            unreachable;
        }
    };
}

pub fn ResultLocationT(comptime Register: type) type {
    return union(ResultLocationTag) {
        const ResultLocation = @This();
        reg: Register,
        addr_reg: AddrRegT(Register),
        int_lit: isize,
        foreign: Symbol,
        string_data: usize,
        float_data: usize,
        double_data: usize,
        local_lable: usize,
        array: []usize,
        uninit,

        pub fn stackBase(off: isize) ResultLocation {
            return .{ .addr_reg = .{
                .reg = .rbp,
                .disp = off,
            } };
        }

        pub const StackTop = struct {
            off: isize,
            size: usize,
        };

        pub fn isMem(self: ResultLocation) bool {
            return switch (self) {
                .addr_reg => true,
                else => false,
            };
        }

        pub fn offsetByByte(self: ResultLocation, off: isize) ResultLocation {
            var clone = self.addr_reg;
            clone.disp += off;
            return .{ .addr_reg = clone };
        }
    };
}

pub fn RegisterManagerT(comptime Register: type, comptime PTR_SIZE: comptime_int, comptime STACK_ALIGNMENT: comptime_int, comptime table: RMTable(Register)) type {
    return struct {
        const RegisterManager = @This();
        const AddrReg = AddrRegT(Register);
        const Sizes = SizeFn(PTR_SIZE, STACK_ALIGNMENT);
        const ResultLocation = ResultLocationT(Register);
        gpa: Allocator,
        unused: Regs, // record of register currently holding some data
        dirty: Regs, // record of volatile registers being used in a function, and thus needs to be restored right before return
        insts: [count]usize, // points to the instruction which allocate the corresponding register in `unused`
        cconv: CallingConvention, // TODO: This prevent us to have different calling convention
        body_writer: *std.Io.Writer,
        results: []ResultLocation,

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
        //
        // stack manipulation
        //
        pub fn enterScope(self: *RegisterManager) void {
            self.scope_stack.append(self.gpa, 0) catch unreachable;
        }

        pub fn exitScope(self: *RegisterManager) void {
            const size = self.scope_stack.pop().?;
            self.frame_usage -= size;
        }

        // This function does not immediately do `sub rsp, ...`, instead it does it `lazily`
        // There is also no ways to revert the effect
        pub fn allocateStack(self: *RegisterManager, size: usize, alignment: usize) isize {
            const new_size = alignAllocRaw(self.frame_usage, size, alignment);
            self.scope_stack.items[self.scope_stack.items.len - 1] += new_size - self.frame_usage;
            self.frame_usage = new_size;
            self.max_usage = @max(self.frame_usage, self.max_usage);
            return -@as(isize, @intCast(self.frame_usage));
        }

        pub fn allocateStackTyped(self: *RegisterManager, t: Type) isize {
            return self.allocateStack(Sizes.typeSize(t), Sizes.alignOf(t));
        }

        // A wrapper around isize. We use this to signify that this offset SHOULD NOT be used directly
        pub const StackTop = struct { off: usize };
        // allocate a temporary memory on the top of the stack, which can be freed by `freeStackTemp`
        // The alignment automatically at least STACK_ALIGNMENT
        // This function returns the offset from stack top (rsp). However,
        // The ACTUAL position could change as new temp comes on top
        // One must use `getStackTop` to get the ACTUAL stack offset
        pub fn allocateStackTemp(self: *RegisterManager, size: usize, alignment: usize) StackTop {
            const new_size = alignAllocRaw(self.temp_usage, size, alignment);
            self.temp_stack.append(self.gpa, new_size - self.temp_usage) catch unreachable;
            self.subStackTop(new_size - self.temp_usage);
            self.temp_usage = new_size;
            return .{ .off = self.temp_usage };
        }
        pub fn allocateStackTempTyped(self: *RegisterManager, t: Type) StackTop {
            return self.allocateStackTemp(Sizes.typeSize(t), @max(Sizes.alignOf(t), STACK_ALIGNMENT));
        }
        pub fn freeStackTemp(self: *RegisterManager) void {
            const size = self.temp_stack.pop().?;
            self.temp_usage -= size;
            self.addStackTop(size);
        }
        pub fn getStackTop(self: RegisterManager, stack_top: StackTop) usize {
            if (stack_top.off > self.temp_usage) @panic("The stack top item has already been freed!");
            return self.temp_usage - stack_top.off;
        }

        pub fn addStackTop(self: RegisterManager, offset: usize) void {
            return table.offset_stack_top(self.body_writer, @intCast(offset));
        }

        pub fn subStackTop(self: RegisterManager, offset: usize) void {
            return table.offset_stack_top(self.body_writer, -@as(isize, @intCast(offset)));
        }
        // --------------------------------------------------------------------------------------------
        pub fn debug(self: RegisterManager) void {
            var it = self.unused.iterator(.{ .kind = .unset });
            while (it.next()) |i| {
                log.debug("{f} inused", .{@as(Register, @enumFromInt(i))});
            }
        }
        pub fn init(cconv: CallingConvention, body_writer: *std.Io.Writer, gpa: std.mem.Allocator, results: []ResultLocation) RegisterManager {
            var dirty = cconv.callee_saved;
            dirty.toggleAll();
            return RegisterManager{
                .gpa = gpa,
                .unused = Regs.initFull(),
                .insts = undefined,
                .dirty = dirty,
                .cconv = cconv,
                .body_writer = body_writer,
                .results = results,
                .frame_usage = 0,
                .max_usage = 0,
                .scope_stack = .empty,
                .temp_usage = 0,
                .temp_stack = .empty,
                .dirty_spilled = std.AutoHashMap(Register, isize).init(gpa),
            };
        }

        pub fn deinit(self: *RegisterManager) void {
            self.scope_stack.deinit(self.gpa);
            self.temp_stack.deinit(self.gpa);
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

        pub fn storeRegAddr(self: RegisterManager, addr: AddrReg, word: Word, src: Register) void {
            table.store_reg_addr(self.body_writer, addr, word, src);
        }

        pub fn loadRegAddr(self: RegisterManager, addr: AddrReg, word: Word, dst: Register) void {
            table.load_reg_addr(self.body_writer, addr, word, dst);
        }

        pub fn saveDirty(self: *RegisterManager, reg: Register) void {
            const off = self.allocateStack(PTR_SIZE, PTR_SIZE);
            self.dirty_spilled.putNoClobber(reg, off) catch unreachable;
            const addr = AddrReg{ .reg = .rbp, .disp = off };
            self.storeRegAddr(addr, Word.fromSize(PTR_SIZE).?, reg);
        }

        pub fn restoreDirty(self: *RegisterManager, reg: Register) void {
            const off = self.dirty_spilled.get(reg) orelse @panic("restoring a register that is not dirty");
            const addr = AddrReg{ .reg = .rbp, .disp = off };
            self.loadRegAddr(addr, Word.fromSize(PTR_SIZE).?, reg);
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

        pub fn consumeResult(self: *RegisterManager, idx: usize) ResultLocation {
            const loc = self.results[idx];
            switch (loc) {
                .reg => |reg| self.markUnused(reg),
                .addr_reg,
                => |addr_reg| {
                    self.markUnused(addr_reg.reg);
                    if (addr_reg.mul) |mul|
                        self.markUnused(mul[0]);
                    },

                    inline .float_data, .double_data, .string_data, .int_lit, .foreign, .local_lable, .array, .uninit => |_| {},
            }
            return loc;
        }

        pub fn print(self: RegisterManager, comptime format: []const u8, args: anytype) void {
            self.body_writer.print(format, args) catch unreachable;
        }

        pub const CallingConvention = struct {
            pub const VTable = struct {
                call: *const fn (i: usize, call: Cir.Inst.Call, reg_manager: *RegisterManager, results: []ResultLocation) void,

                prolog: *const fn (self: Cir, reg_manager: *RegisterManager, results: []ResultLocation) void,
                epilog: *const fn (reg_manager: *RegisterManager, results: []ResultLocation, ret_t: Type, i: usize) void,
            };
            vtable: VTable,
            callee_saved: RegisterManager.Regs,
            pub fn makeCall(cconv: CallingConvention, i: usize, call: Cir.Inst.Call, reg_manager: *RegisterManager, results: []ResultLocation) void {
                cconv.vtable.call(i, call, reg_manager, results);
            }
            pub fn prolog(cconv: CallingConvention, self: Cir, reg_manager: *RegisterManager, results: []ResultLocation) void {
                cconv.vtable.prolog(self, reg_manager, results);
            }
            pub fn epilog(cconv: CallingConvention, reg_manager: *RegisterManager, results: []ResultLocation, ret_t: Type, i: usize) void {
                cconv.vtable.epilog(reg_manager, results, ret_t, i);
            }
        };


        // Given the position and class of the argument, return the register for this argument,
        // or null if it should be passe on the stack

    };
}

pub fn RMTable(comptime Register: type) type {
    return struct {
        const AddrReg = AddrRegT(Register);
        offset_stack_top: fn (writer: *std.Io.Writer, offset: isize) void,
        store_reg_addr: fn (writer: *std.Io.Writer, addr: AddrReg, word: Word, src: Register) void,
        load_reg_addr: fn (writer: *std.Io.Writer, addr: AddrReg, word: Word, dst: Register) void,
    };
}

pub fn MovTable(comptime STACK_ALIGNMENT: comptime_int, comptime PTR_SIZE: comptime_int, comptime Register: type, rm_table: RMTable(Register)) type {
    const AddrReg = AddrRegT(Register);
    const RegisterManager = RegisterManagerT(Register, PTR_SIZE, STACK_ALIGNMENT, rm_table);
    const ResultLocation = ResultLocationT(Register);

    return struct {
        mov_addr_to_reg: fn (rm: *RegisterManager, addr: AddrReg, word: Word, dst: Register) void,
        mov_loc_to_reg: fn (rm: *RegisterManager, src: ResultLocation, dst: Register, size: usize) void,
        mov_loc_to_addr_reg: fn (rm: *RegisterManager, src: ResultLocation, addr: AddrReg, word: Word) void,
    };
}

pub fn PrintTable(comptime Register: type) type {
    return struct {
        print_loc: fn (writer: *std.Io.Writer, loc: ResultLocationT(Register), Word) void,
        print_addr_reg: fn (writer: *std.Io.Writer, AddrRegT(Register), Word) void,
    };
}

pub fn Print(comptime Register: type, p_table: PrintTable(Register)) type {
    return struct {
        pub fn select_fn(comptime T: type) fn (*std.Io.Writer, T, Word) void {
            return switch (T) {
                AddrRegT(Register) => p_table.print_addr_reg,
                ResultLocationT(Register) => p_table.print_loc,
                else => {
                    @compileError("unsupported type " ++ @typeName(T) ++ " to print");
                }
            };
        }
        pub fn print(a: anytype, word: Word) PrintImpl(@TypeOf(a), select_fn(@TypeOf(a))) {
            return PrintImpl(@TypeOf(a), select_fn(@TypeOf(a))) {
                .t = a,
                .word = word
            };
        }
    };
}

pub fn PrintImpl(comptime T: type, print_fn: fn (*std.Io.Writer, T, Word) void) type {
    const s = struct {
        t: T,
        word: Word,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            print_fn(writer, self.t, self.word); 
        }

        pub fn print(t: T, word: Word) @This() {
            return .{
                .t = t,
                .word = word,
            };
        }
    };

    return s;
}

pub fn ArchDetails(
    comptime STACK_ALIGNMENT: comptime_int, comptime PTR_SIZE: comptime_int, 
    comptime Register: type,
    comptime rm_table: RMTable(Register),
    comptime mov_table: MovTable(STACK_ALIGNMENT, PTR_SIZE, Register, rm_table)) type {
    return struct {
        const AddrReg = AddrRegT(Register);
        const RegisterManager = RegisterManagerT(Register, PTR_SIZE, STACK_ALIGNMENT, rm_table);
        const ResultLocation = ResultLocationT(Register);
        const Sizes = SizeFn(PTR_SIZE, STACK_ALIGNMENT);

        pub fn offsetLoc(loc: ResultLocation, pos: usize, t: Type) ResultLocation {
            const t_full = TypePool.lookup(t);
            const total_off: isize =
                switch (t_full) {
                    .tuple => |tuple| @intCast(Sizes.tupleOffset(tuple.els, pos)),
                    .named => |named| @intCast(Sizes.tupleOffset(named.els, pos)),
                    .array => |array| blk: {
                        const sub_t = array.el;
                        break :blk @intCast(Sizes.typeSize(sub_t) * pos);
                    },
                    else => unreachable,
                };
            return switch (loc) {
                .addr_reg => |addr_reg| .{ .addr_reg = .{ .disp = total_off + addr_reg.disp, .reg = addr_reg.reg } },
                else => unreachable,
            };
        }

        // @arch_specific
        pub fn moveAddrToReg(src: AddrReg, dst: Register, reg_manager: *RegisterManager) void {
            mov_table.mov_addr_to_reg(reg_manager, src, Word.fromSize(PTR_SIZE).?, dst);
        }

        pub fn moveLocToGpReg(src: ResultLocation, size: usize, inst: usize, reg_manager: *RegisterManager) Register {
            switch (src) {
                .reg => |reg| {
                    if (RegisterManager.GpMask.isSet(@intFromEnum(reg))) {
                        reg_manager.markUsed(reg, inst);
                        return reg;
                    }
                },
                else => {},
            }
            const gp_reg = reg_manager.getUnused(inst, RegisterManager.GpMask) orelse unreachable;
            moveLocToReg(src, gp_reg, size, reg_manager);
            return gp_reg;
        }

        // @arch_specific
        pub fn moveLocToReg(src: ResultLocation, reg: Register, size: usize, reg_manager: *RegisterManager) void {
            mov_table.mov_loc_to_reg(reg_manager, src, reg, size);
        }

        // the offset is NOT multiple by platform size
        pub fn moveLocToStackBase(src: ResultLocation, off: isize, size: usize, reg_man: *RegisterManager) void {
            return moveLocToAddrReg(src, .{ .reg = .rbp, .disp = off }, size, reg_man);
        }

        pub fn moveLocToAddrReg(src: ResultLocation, reg: AddrReg, size: usize, rm: *RegisterManager) void {
            if (src == .uninit) return;
            if (Word.fromSize(size)) |word| {
                return moveLocToAddrRegWord(src, reg, word, rm);
            }
            var self_clone = src;
            switch (self_clone) {
                .array => |array| {
                    const sub_size = @divExact(size, array.len);
                    for (array, 0..array.len) |el_inst, i| {
                        const loc = rm.consumeResult(el_inst);
                        moveLocToAddrReg(loc, .{ .reg = reg.reg, .disp = reg.disp + @as(isize, @intCast(sub_size * i)) }, sub_size, rm);
                    }
                    return;
                },
                .addr_reg => |_| {
                    const off = &self_clone.addr_reg.disp;
                    //reg_man.markUsed(self_clone.addr_reg.reg, null);
                    rm.unused.unset(@intFromEnum(self_clone.addr_reg.reg));
                    const reg_size = PTR_SIZE;
                    var size_left = size;
                    while (size_left > reg_size) : (size_left -= reg_size) {
                        moveLocToAddrRegWord(self_clone, .{ .reg = reg.reg, .disp = reg.disp + @as(isize, @intCast(size - size_left)), .mul = reg.mul }, .qword, rm);
                        off.* += reg_size;
                    }
                    moveLocToAddrRegWord(self_clone, .{ .reg = reg.reg, .disp = reg.disp + @as(isize, @intCast(size - size_left)), .mul = reg.mul }, Word.fromSize(size_left).?, rm);
                    rm.unused.set(@intFromEnum(self_clone.addr_reg.reg));
                    //reg_man.markUnused(self_clone.addr_reg.reg);
                },
                else => unreachable,
            }
        }

        // @arch_specific
        pub fn moveLocToAddrRegWord(src: ResultLocation, addr: AddrReg, word: Word, reg_man: *RegisterManager) void {
            mov_table.mov_loc_to_addr_reg(reg_man, src, addr, word); 
        }

    };
}
