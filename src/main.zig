const std = @import("std");
const assert = std.debug.assert;
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Token = Lexer.Token;

fn usage(proc_name: []const u8) void {
    std.debug.print("usage: {s} <src_path>\n", .{proc_name});
}
const Mode = enum {
    eval,
    compile,
    help,
    pub fn fromString(s: []const u8) CliError!Mode {
        return 
            if (std.mem.eql(u8, "-e", s)) Mode.eval 
            else if (std.mem.eql(u8, "-c", s)) Mode.compile
            else if (std.mem.eql(u8, "-h", s)) Mode.help
            else CliError.InvalidOption;
    }
    pub fn usage() void {
        log.err("Expect option `-c`, `-s`, or `-h`", .{});
    }
};
const CliError = error {
    InvalidOption,
    TooFewArgument,
};
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = std.process.args();
    const proc_name = args.next().?;
    errdefer usage(proc_name);

    const mode = Mode.fromString(args.next() orelse {
        Mode.usage();
        return CliError.TooFewArgument;
    }) catch |e| {
        Mode.usage();
        return e;
    };
    const src_path = args.next() orelse return CliError.TooFewArgument;
    const cwd = std.fs.cwd();
    const src_f = try cwd.openFile(src_path, .{});
    const src = try src_f.readToEndAlloc(alloc, 1000);
    defer alloc.free(src);

    var lexer = Lexer.init(src, src_path);

    // while (try lexer.next()) |tk| {
    //     log.debug("token: {}", .{tk});
    // }
    // lexer = Lexer.init(src, src_path);
    var ast = try Ast.parse(&lexer, alloc);
    defer ast.deinit(alloc);
    switch (mode) {
        .eval => try ast.eval(alloc),
        .compile => @panic("TODO"),
        .help => @panic("TODO"),
    }
}
