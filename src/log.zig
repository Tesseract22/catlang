const std = @import("std");
const Color = std.io.tty.Color;
const Config = std.io.tty.Config;
var config_lazy: ?Config = null;
var stderr: std.fs.File = undefined;
pub fn init() void {
    stderr = std.io.getStdErr();
}
pub fn print(prefix: []const u8, color: Color, comptime fmt: []const u8, args: anytype) void {
    if (config_lazy == null) config_lazy = std.io.tty.detectConfig(stderr);
    const config = config_lazy.?;
    var writer = stderr.writer();
    config.setColor(writer, color) catch unreachable;
    _ = writer.writeAll(prefix) catch unreachable;
    config.setColor(writer, Color.white) catch unreachable;
    writer.print(fmt ++ "\n", args) catch unreachable;
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
