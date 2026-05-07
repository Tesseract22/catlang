const std = @import("std");
const Io =  std.Io;
const Terminal = Io.Terminal;
const Color = Terminal.Color;

var stderr_file: Io.File = undefined;
var stderr_buf: [64]u8 = undefined;
var stderr_writer: Io.File.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

var term: Terminal = undefined;

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

pub fn init(io: Io) void {
    stderr_file = Io.File.stderr();
    stderr_writer = stderr_file.writer(io, &stderr_buf);
    stderr = &stderr_writer.interface;
    const mode =  Io.Terminal.Mode.detect(io, stderr_file, false, false) catch unreachable;
    term = .{ .mode = mode, .writer = stderr };
}
pub fn print(level: Level, color: Color, comptime fmt: []const u8, args: anytype) void {
    if (level == .debug and !enable_debug)
        return;
    term.setColor(color) catch unreachable;
    _ = stderr.writeAll(level.to_str()) catch unreachable;
    term.setColor(Color.white) catch unreachable;
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
