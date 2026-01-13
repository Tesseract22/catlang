const std = @import("std");
const Color = std.io.tty.Color;
const Config = std.io.tty.Config;
var config_lazy: ?Config = null;
var stderr_file: std.fs.File = undefined;
var stderr_buf: [0]u8 = undefined;
pub fn init() void {
    stderr_file = std.fs.File.stderr();
}
pub fn print(prefix: []const u8, color: Color, comptime fmt: []const u8, args: anytype) void {
    if (config_lazy == null) config_lazy = std.io.tty.detectConfig(stderr_file);
    const config = config_lazy.?;
    var writer = stderr_file.writer(&stderr_buf);
    const stderr = &writer.interface;
    config.setColor(stderr, color) catch unreachable;
    _ = stderr.writeAll(prefix) catch unreachable;
    config.setColor(stderr, Color.white) catch unreachable;
    stderr.print(fmt ++ "\n", args) catch unreachable;
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print("Error: ", Color.red, fmt, args);
}
pub fn note(comptime fmt: []const u8, args: anytype) void {
    print("Note: ", Color.blue, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    print("Debug: ", Color.yellow, fmt, args);
}
