const std = @import("std");


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
    pub const R32 = enum { 
        eax,
        ebx,
        ecx,
        edx,
        esi,
        edi,
        ebp,
        esp,
        r8d,
        r9d,
        r10d,
        r11d,
        r12d,
        r13d,
        r14d,
        r15d,
        pub fn format(value: R32, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = try writer.writeAll(@tagName(value));
        }
    };
    pub const R16 = enum {
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
    };
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
            2 => @tagName(@as(R16, @enumFromInt(@intFromEnum(self)))),
            4 => @tagName(@as(R32, @enumFromInt(@intFromEnum(self)))),
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


