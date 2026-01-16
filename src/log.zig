const std = @import("std");
const Color = std.io.tty.Color;
const Config = std.io.tty.Config;

var config: Config = undefined;

var stderr_file: std.fs.File = undefined;
var stderr_buf: [64]u8 = undefined;
var stderr_writer: std.fs.File.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

pub var enable_debug = true;

pub const Level = enum {
    debug,
    note,
    err,

    pub fn to_str(level: Level) []const u8 {
        return switch (level) {
            .debug => "debug",
            .note => "note",
            .err => "error"
        };
    }
};

pub fn init() void {
    stderr_file = std.fs.File.stderr();
    stderr_writer = stderr_file.writer(&stderr_buf);
    stderr = &stderr_writer.interface;
    config = std.io.tty.Config.detect(stderr_file);
}
pub fn print(level: Level, color: Color, comptime fmt: []const u8, args: anytype) void {
    if (level == .debug and !enable_debug)
        return;
    config.setColor(stderr, color) catch unreachable;
    _ = stderr.writeAll(level.to_str()) catch unreachable;
    config.setColor(stderr, Color.white) catch unreachable;
    stderr.print(": " ++ fmt ++ "\n", args) catch unreachable;
    stderr.flush() catch unreachable;
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(.err, Color.red, fmt, args);
}
pub fn note(comptime fmt: []const u8, args: anytype) void {
    print(.note, Color.blue, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    print(.debug, Color.yellow, fmt, args);
}

pub fn line(level: Level) void {
    if (level == .debug and !enable_debug)
        return;
    stderr.writeByte('\n') catch unreachable;
    stderr.flush() catch unreachable;
}
