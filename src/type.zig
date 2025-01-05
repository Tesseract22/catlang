// the new version of our type system. I hope this is better!
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Type = u32;
pub const Decl = u32;
pub const TypeStorage = struct {
    kind: Kind,
    more: u32,
};
pub const Kind = enum(u8) {
    float,          // leaf
    int,            // leaf
    bool,           // leaf
    void,           // leaf
    ptr,            // more points to another Type
    array,          // more is an index in extra as len,el
    tuple,          // more is an index in extra as len,el1,el2,el3...
};
pub const TypeFull = union(Kind) {
    float,
    int,
    bool,
    void,
    ptr: Ptr,
    array: Array,
    tuple: Tuple,
   
    pub const Ptr = struct {
        el: Type
    };
    pub const Array = struct {
        el: Type,
        size: u32,
    };
    pub const Tuple = struct {
        els: []Type,
    };
    pub const Adapter = struct {
        extras: *std.ArrayList(u32),
        pub fn eql(ctx: Adapter, a: TypeFull, b: TypeStorage, b_idx: usize) bool {
            _ = b_idx;
            if (std.meta.activeTag(a) != b.kind) return false;
            switch (a) {
                .float,
                .int,
                .bool,
                .void => return true,
                .ptr => |ptr| return ptr.el == b.more,
                .array => |array| return array.el == ctx.extras.items[b.more] and array.size == ctx.extras.items[b.more + 1],
                .tuple => |tuple| {
                    if (tuple.els.len != ctx.extras.items[b.more]) return false;
                    for (tuple.els, 1..) |t, i| {
                        if (t != ctx.extras.items[b.more + i]) return false;
                    } else return true;
                },
            }
        }
        pub fn hash(ctx: Adapter, a: TypeFull) u32 {
            _ = ctx;
            return switch (a) {
                .float,
                .int,
                .bool,
                .void => std.hash.uint32(@intFromEnum(a)),
                inline .ptr, .array => |x| @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&x))),
                .tuple => |tuple| blk: {
                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHash(&hasher, std.meta.activeTag(a));
                    for (tuple.els) |t| {
                        std.hash.autoHash(&hasher, t);
                    }
                    break :blk @truncate(hasher.final());
                }
            };
        }
    };
};
pub const TypeIntern = struct {
    const Self = @This();
    map: std.AutoArrayHashMap(TypeStorage, void),
    extras: std.ArrayList(u32),
    pub fn get_new_extra(self: TypeIntern) u32 {
        return @intCast(self.extras.items.len);
    }
    pub fn init(a: Allocator) Self {
        var res = TypeIntern { .map = std.AutoArrayHashMap(TypeStorage, void).init(a), .extras = std.ArrayList(u32).init(a) };
        int = res.intern(TypeFull.int);
        @"void" = res.intern(TypeFull.void);
        float = res.intern(TypeFull.float);
        @"bool" = res.intern(TypeFull.bool);
        string = res.intern(TypeFull {.})
        return res;
    }
    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.extras.deinit();
    }
    pub fn intern(self: *Self, s: TypeFull) Type {
        const gop = self.map.getOrPutAdapted(s, TypeFull.Adapter {.extras = &self.extras}) catch unreachable; // ignore out of memory
        const more = switch (s) {
            .float,
            .int,
            .bool,
            .void => undefined,
            .ptr => |ptr| ptr.el,
            .array => |array| blk: {
                const extra_idx = self.get_new_extra();
                self.extras.append(array.el) catch unreachable;
                self.extras.append(array.size) catch unreachable;
                break :blk extra_idx;
            },
            .tuple => |tuple| blk: {
                const extra_idx = self.get_new_extra();
                self.extras.append(@intCast(tuple.els.len)) catch unreachable;
                for (tuple.els) |t| {
                    self.extras.append(t) catch unreachable;
                }
                break :blk extra_idx;
            },

        };
        gop.key_ptr.* = TypeStorage {.more = more, .kind = std.meta.activeTag(s)};
        return @intCast(gop.index);
    }
    pub fn intern_exist(self: *Self, s: TypeFull) Type {
        return self.map.getIndex(s);
    }
    // assume the i is valid
    pub fn lookup(self: Self, i: Type, a: Allocator) TypeFull {
        const storage = self.map.keys()[i];
        const more = storage.more;
        switch (storage.kind) {
            .float => return.float,
            .int => return .int,
            .bool => return .bool,
            .void => return .void,
            .ptr => return .{.ptr = .{.el = self.extras.items[more]}},
            .array => return .{.array = .{.el = self.extras.items[more], .size = self.extras.items[more + 1]}},
            .tuple => {
                const size = self.extras.items[more];
                const tuple = a.dupe(Type, self.extras.items[more + 1..more + 1 + size]) catch unreachable;
                return .{.tuple = .{.els = tuple}};
            },

        }
    }
    pub fn len(self: Self) usize {
        return self.map.keys().len;
    }
};
// Some commonly used type and typechecking. We cached them so when we don't have to intern them every time.
// They are initialized in TypeIntern.init
pub var int:        Type = undefined;
pub var @"bool":    Type = undefined;
pub var @"void":    Type = undefined;
pub var float:      Type = undefined;
pub var string:     Type = undefined;

pub var type_pool: TypeIntern = undefined;
pub fn intern(s: TypeFull) Type {
    return type_pool.intern(s);
}

pub fn lookup(i: Type, a: Allocator) TypeFull {
    return type_pool.lookup(i, a);
}

test TypeIntern {
    const equalDeep = std.testing.expectEqualDeep;
    const a = std.testing.allocator;
    type_pool = TypeIntern.init(a);
    defer type_pool.deinit();

    const int_type = TypeFull.int;
    const float_type = TypeFull.float;

    const t1 = type_pool.intern(int_type);
    const t2 = type_pool.intern(float_type);

    const int_type2 = type_pool.lookup(t1, a);
    const float_type2 = type_pool.lookup(t2, a);

    try equalDeep(int_type, int_type2);
    try equalDeep(float_type, float_type2);

    const int4_type = TypeFull {.array = .{.el = t1, .size = 4}}; 
    const int6_type = TypeFull {.array = .{.el = t1, .size = 6}}; 

    const t3 = type_pool.intern(int4_type);
    const t4 = type_pool.intern(int6_type);
    const int4_type2 = type_pool.lookup(t3, a);
    const int6_type2 = type_pool.lookup(t4, a);

    try equalDeep(int4_type, int4_type2);
    try equalDeep(int6_type, int6_type2);
}
