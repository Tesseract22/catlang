const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Symbol = u32;
pub const StringInternPool = struct {
    const Self = @This();
    map: std.array_hash_map.String(void),
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    pub fn init(gpa: Allocator) Self {
        return .{ .map = .empty, .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }
    pub fn deinit(self: *Self) void {
        self.map.deinit(self.gpa);
    }
    pub fn intern(self: *Self, s: []const u8) Symbol {
        const gop = self.map.getOrPut(self.gpa, s) catch @panic("OOM");
        if (!gop.found_existing) gop.key_ptr.* = self.arena.allocator().dupe(u8, s) catch @panic("OOM");
        return @intCast(gop.index);
    }
    pub fn intern_exist(self: *Self, s: []const u8) ?Symbol {
        return @intCast(self.map.getIndex(s));
    }

    // assume the i is valid
    pub fn lookup(self: Self, i: u32) []const u8 {
        return self.map.keys()[i];
    }
    pub fn len(self: Self) usize {
        return self.map.keys().len;
    }
};

pub fn InternPool(comptime T: type) type {
    return struct {
        const Self = @This();
        map: std.AutoArrayHashMap(T, void),
        pub fn init(a: Allocator) Self {
            return .{ .map = std.StringArrayHashMap(void).init(a) };
        }
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }
        pub fn intern(self: *Self, s: T) usize {
            const gop = self.map.getOrPut(s) catch unreachable; // ignore out of memory
            return gop.index;
        }
        pub fn intern_exist(self: *Self, s: T) ?usize {
            return self.map.getIndex(s);
        }

        // assume the i is valid
        pub fn lookup(self: Self, i: u32) T {
            return self.map.keys()[i];
        }
        pub fn len(self: Self) usize {
            return self.map.keys().len;
        }
    };
}
