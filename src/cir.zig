const std = @import("std");
const Ast = @import("ast.zig");
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
};
const RegisterManager = struct {

    unused: Regs,
    const count = @typeInfo(Register).Enum.fields.len;
    pub const Regs = std.bit_set.ArrayBitSet(u8, count);
    pub fn init() RegisterManager {
        return RegisterManager {.unused = Regs.initFull() };
    }
    pub fn getUnused(self: *RegisterManager) ?Register {
        const idx = self.unused.findFirstSet() orelse return null;
        self.unused.set(idx);
        return @enumFromInt(idx);
    }
};
const ResultLocation = union(enum) {
    reg: Register,
    stack_top: usize,
    stack_base: usize,
};
const Inst = union(enum) {
    // add,
    function: Fn,
    ret: usize, // index
    call: []const u8,
    arg: ScopeItem,
    arg_decl: Ast.Type,
    lit: Ast.Val,
    var_access: usize, // the instruction where it is defined
    var_decl: Ast.Type,
    print: Ast.Type,

    pub const Fn = struct {
        name: []const u8,
        scope: Scope,
    };
    pub fn format(value: Inst, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.print("{s} ", .{@tagName(value)});
        switch (value) {
            .function => |f| try writer.print("{s}", .{f.name}),
            .call => |s| try writer.print("{s}", .{s}),
        
            inline
            .var_decl,
            .ret,
            .arg_decl,
            .var_access,
            .print,
            .arg,
            .lit => |x| try writer.print("{}", .{x}),
        }
}
};
const ScopeItem = struct {
    t: Ast.Type,
    i: usize,
};
const Scope = std.StringArrayHashMap(ScopeItem);
    
const ZirGen = struct {
    insts: std.ArrayList(Inst),
    ast: *const Ast,
    scope: Scope,
    gpa: std.mem.Allocator,
};
const Cir = @This();
insts: []Inst,

pub fn typeSize(t: Ast.Type) usize {
    return switch (t) {
        .float => 8,
        .int => 8,
        .string => 8,
        .void => 0,
    };
}
pub fn compile(self: Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator) !void {
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init();
    try file.print(builtinData ++ builtinText ++ builtinShow ++ builtinStart, .{});
    var scope_size: usize = 0;
    var scope: *Scope = undefined;
    for (self.insts, 0..) |*inst_ptr, i| {
        var inst: Inst = inst_ptr.*;
        switch (inst) {
            .function => |*f| {
                try file.print("{s}:\n", .{f.name});
                try file.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
                var frame_size: usize = 0;
                var it = f.scope.iterator();
                while (it.next()) |entry| {
                    frame_size += typeSize(entry.value_ptr.t);
                }
                try file.print("\tsub rsp, {}\n", .{frame_size});
                scope = &f.scope;

            },
            .ret => |ret| {
                var frame_size: usize = 0;
                var it = self.insts[ret].function.scope.iterator();
                while (it.next()) |entry| {
                    frame_size += typeSize(entry.value_ptr.t);
                }
                try file.print("\tadd rsp, {}\n", .{frame_size});
                try file.print("\tpop rbp\n", .{});
                try file.print("\tret\n", .{});
            },
            .lit => |lit| {
                const result_reg = reg_manager.getUnused() orelse @panic("TODO");
                switch (lit) {
                    .int => |int| try file.print("\tmov {s}, {}\n", .{@tagName(result_reg), int}),
                    else => @panic("TODO"),
                }
                results[i] = ResultLocation {.reg = result_reg}; 
            },
            .var_decl => |var_decl| {
                const size = typeSize(var_decl);
                scope_size += size;
                // TODO explicit operand position
                const loc = results[i - 1];
                switch (loc) {
                    .reg => |reg| {
                        try file.print("\tmov [rbp - {}], {s}\n", .{scope_size, @tagName(reg)});
                        results[i] = loc; 

                    },
                    else => @panic("TODO"),
                }
                // try file.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const inst_decl = self.insts[var_access];
                _ = inst_decl; // autofix
                // switch (inst_decl) {
                //     .var_decl => |s| {
                //         switch (loc) {}
                //     },
                //     .arg_decl => |s| {
                //         _ = s; // autofix
                //     },
                //     else => unreachable,
                // }
                const loc = results[var_access];
                results[i] = loc;

                
            },
            .arg_decl => |arg_decl| {
                _ = arg_decl; // autofix
                // TODO handle differnt type
                // TODO handle different number of argument
                const rdi = @intFromEnum(Register.rdi);
                reg_manager.unused.set(rdi);
                results[i] = ResultLocation {.reg = Register.rdi};
                
            },
            .call => |f| {
                try file.print("\tcall {s}\n", .{f}); // TODO handle return
            },
            .arg => |arg| {
                const loc = results[arg.i];
                switch (arg.t) {
                    .int => {
                        switch (loc) {
                            .reg => |reg| {
                                try file.print("\tmov rdi, {s}\n", .{@tagName(reg)});
                            },
                            else => @panic("TODO"),
                        }
                    },
                    else => @panic("TDOO"),
                }

            },
            .print => |t| {
                const loc = results[i - 1];
                switch (t) {
                    .int => {
                        try file.print("\tmov rsi, {s}\n" ++ "\tmov rdi, format\n" ++  "\tmov rax, 0\n" ++ "\tcall align_printf\n", .{@tagName(loc.reg)});
                    },
                    else => @panic("TODO"),
                }
            },
        }
    }
}
pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            .function => |*f| {
                f.scope.deinit();
            },
            else => {},
        }
    }
    alloc.free(self.insts);

}
pub fn generate(ast: Ast, alloc: std.mem.Allocator) CompileError!Cir {
    var zir_gen = ZirGen {.ast = &ast, .insts = std.ArrayList(Inst).init(alloc), .scope = Scope.init(alloc), .gpa = alloc };
    defer zir_gen.scope.deinit();
    for (ast.defs) |def| {
        try generateProc(def, &zir_gen);
    }
    // errdefer zir_gen.insts.deinit();

    return Cir {.insts = zir_gen.insts.toOwnedSlice() catch unreachable};
    
}
pub fn generateProc(def: Ast.ProcDef, zir_gen: *ZirGen) CompileError!void {
    zir_gen.insts.append(Inst {.function = Inst.Fn {.name = def.data.name, .scope = undefined}}) catch unreachable;
    const idx = zir_gen.insts.items.len - 1;
    for (def.data.args) |arg| {
        zir_gen.scope.put(arg.name, ScopeItem {.i = zir_gen.insts.items.len, .t = arg.type}) catch unreachable;
        zir_gen.insts.append(Inst {.arg_decl = arg.type}) catch unreachable;
    }
    for (def.data.body) |stat_id| {
        try generateStat(zir_gen.ast.stats[stat_id.idx], zir_gen);
    }
    zir_gen.insts.items[idx].function.scope = zir_gen.scope;
    zir_gen.scope = Scope.init(zir_gen.gpa);


    zir_gen.insts.append(Inst {.ret = idx}) catch unreachable;


}
pub fn generateStat(stat: Ast.Stat, zir_gen: *ZirGen) CompileError!void {
    switch (stat.data) {
        .anon => |expr| _ = try generateExpr(zir_gen.ast.exprs[expr.idx], zir_gen),
        .var_decl => |var_decl| {
            // var_decl.
            const expr_type = try generateExpr(zir_gen.ast.exprs[var_decl.expr.idx], zir_gen);
            if (zir_gen.scope.fetchPut(var_decl.name, .{.t = expr_type, .i = zir_gen.insts.items.len}) catch unreachable) |_| {
                log.err("{} Identifier redefined: `{s}`", .{stat.tk.loc, var_decl.name});
                // TODO provide location of previously defined variable
                return CompileError.Undefined;
            }
            zir_gen.insts.append(.{.var_decl = expr_type}) catch unreachable;
        }
    }

}
pub fn generateExpr(expr: Ast.Expr, zir_gen: *ZirGen) CompileError!Ast.Type {
    switch (expr.data) {
        .atomic => |atomic| return try generateAtomic(atomic, zir_gen),
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{expr.tk});
                    return CompileError.TypeMismatched;
                }

                const t = try generateExpr(zir_gen.ast.exprs[fn_app.args[0].idx], zir_gen);
                zir_gen.insts.append(Inst {.print = t}) catch unreachable;
                return Ast.Type.void;
            }
            const fn_def = for (zir_gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{expr.tk, fn_app.func});
                return CompileError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{expr.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return CompileError.TypeMismatched;
            }
            var fn_eval_scope = std.StringHashMap(Ast.VarBind).init(zir_gen.scope.allocator); // TODO account for global variable
            defer fn_eval_scope.deinit();

            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = zir_gen.ast.exprs[fa.idx];
                const e_type = try generateExpr(e, zir_gen);
                if (@intFromEnum(e_type) != @intFromEnum(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{e.tk.loc, i, fn_app.func, fd.type, @tagName(e_type) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return CompileError.TypeMismatched;
                }
                const entry = fn_eval_scope.fetchPut(fd.name, Ast.VarBind {.name = fd.name, .tk = fd.tk, .type = e_type}) catch unreachable; // TODO account for global variable
                if (entry) |_| {
                    log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{expr.tk, i, fn_app.func, fd.name });
                    // TODO provide location of previously defined variable
                    return CompileError.Redefined;
                }
                zir_gen.insts.append(Inst {.arg = ScopeItem {.i = zir_gen.insts.items.len - 1, .t = e_type}}) catch unreachable;
            }
            zir_gen.insts.append(.{.call = fn_app.func}) catch unreachable;

            // for (fn_def.data.body) |di| {
            //     const stat = zir_gen.ast.stats[di.idx];
            //     try generateStat(stat, zir_gen);
            // }

            return Ast.Type.void;
        }
    }

}
pub fn  generateAtomic(atomic: Ast.Atomic, zir_gen: *ZirGen) CompileError!Ast.Type {
    switch (atomic.data) {
        .float => |f| {
            zir_gen.insts.append(Inst {.lit = .{ .float =  f}}) catch unreachable;
            return Ast.Type.float;
        },
        .int => |i| {
            zir_gen.insts.append(Inst {.lit = .{ .int =  i}}) catch unreachable;
            return Ast.Type.int;
        },
        .string => |s| {
            zir_gen.insts.append(Inst {.lit = .{ .string =s}}) catch unreachable;
            return Ast.Type.string;
        },
        .paren => |e| {
            return try generateExpr(zir_gen.ast.exprs[e.idx], zir_gen);
        },
        .iden => |i| {
            const t = zir_gen.scope.get(i) orelse {
                log.err("{} Undefined identifier: {s}", .{atomic.tk.loc, i});
                return CompileError.Undefined;
            };
            zir_gen.insts.append(Inst {.var_access = t.i}) catch unreachable;
            return t.t;

        }
    }

}


const builtinData = 
    \\section        .data  
    \\    format        db "= %i", 0xa, 0x0
    \\    formatf        db "= %f", 0xa, 0x0
    \\
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


const builtinStart = "_start:\n\tcall main\n\tmov rdi, rax\n\tcall exit\n";
const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";