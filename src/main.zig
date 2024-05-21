const std = @import("std");
const assert = std.debug.assert;
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Token = Lexer.Token;

fn usage(proc_name: []const u8) void {
    std.debug.print("usage: {s} <src_path>\n", .{proc_name});
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = std.process.args();
    const proc_name = args.next().?;
    const src_path = args.next() orelse {
        usage(proc_name);
        return;
    };
    const cwd = std.fs.cwd();
    const src_f = try cwd.openFile(src_path, .{});
    const src = try src_f.readToEndAlloc(alloc, 1000);
    defer alloc.free(src);

    var lexer = Lexer.init(src, src_path);

    while (try lexer.next()) |tk| {
        std.log.debug("token: {}", .{tk});
    }
    lexer = Lexer.init(src, src_path);
    var ast = try Ast.parse(&lexer, alloc);
    defer ast.deinit(alloc);
    std.log.info("defs: {}, stats: {}, exprs: {}", .{ ast.defs.len, ast.stats.len, ast.exprs.len });
    ast.eval(alloc);
}
