const Token = @import("lexer.zig").Token;
const std = @import("std");
pub const VarBind = struct {
    type: TypeExpr,
    name: []const u8,
    tk: Token,
};
pub const TypeEnv = std.StringHashMap(TypeExpr);


pub const Type = union(enum) {
    int,
    float,
    char,
    bool,
    void,
    ptr,
    array: usize,
    tuple: []TypeExpr,
    named: []VarBind,
    iden: []const u8,
    pub fn isTerm(t: Type) bool {
        return switch (t) {
            .array, .ptr => false,
            else => true
        };
    }
    pub fn fromEnv(self: Type, env: TypeEnv) ?TypeExpr {
        return if (self == .iden) env.get(self.iden) orelse null else .{.singular = self};
    }
    pub fn isBuiltinType(iden: []const u8) ?Type {
        const bultin = .{
        .{ "int", Type.int },
        .{ "float", Type.float },
        .{ "bool", Type.bool },
        .{ "char", Type.char },
        };
        return inline for (bultin) |f| {
            if (std.mem.eql(u8, f[0], iden)) break f[1];
        } else null; 
    }
    pub fn fromToken(t: Token) ?Type {
        return switch (t.data) {
            .iden => |i| isBuiltinType(i) orelse . {.iden = i},
            .times => .ptr,
            else => null,
        }; 

    }
    pub fn eq(self: Type, other: Type, env: TypeEnv) bool {
        if (other == .iden) return (TypeExpr {.singular = self}).eq(other.fromEnv(env) orelse return false, env);
        return switch (self) {
            .array => |len| other == .array and other.array == len,
            .tuple => |tuple| other == .tuple and tuple.len == other.tuple.len and for (tuple, other.tuple) |a, b| {
                if (!a.eq(b, env)) return false;
            } else true,
            .named => |tuple| other == .named and tuple.len == other.named.len and  for (tuple, other.named) |a, b| {
                if (!a.type.eq(b.type, env) or !std.mem.eql(u8, a.name, b.name)) return false; // TODO allow different order?
            } else true,
            .iden => |iden| (env.get(iden) orelse return false).eq(.{ .singular = other}, env), 
            else => @intFromEnum(self) == @intFromEnum(other),
        };
    }
    pub fn format(value: Type, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {

        switch (value) {
            .ptr => _ = try writer.write("*"),
            .array => |size| try writer.print("[{}]", .{size}),
            .tuple => |tuple| {
                try writer.print("{{", .{});
                for (tuple) |t| {
                    try writer.print("{}, ", .{t});
                }
                try writer.print("}}", .{});
            },
            .named => |tuple| {
                try writer.print("{{", .{});
                for (tuple) |vb| {
                    try writer.print(".{s}: {}, ", .{vb.name, vb.type});
                }
                try writer.print("}}", .{});
            },
            .iden => |iden| {
                try writer.print("\"", .{});
                try writer.print("{s}", .{iden});
                try writer.print("\"", .{});
            },
            else => _ = try writer.write(@tagName(value)),
        }
    }
};
pub const TypeExpr = union(enum) {
    singular: Type,
    plural: []Type,
    pub fn string(arena: std.mem.Allocator) TypeExpr {
        const ts = arena.dupe(Type, &.{.ptr, .char}) catch unreachable;
        return .{.plural = ts};
    }
    pub fn prefixWith(arena: std.mem.Allocator, sub_type: TypeExpr, new_type: Type) TypeExpr {
        switch (sub_type) {
            .singular => |t| {
                const ts = arena.dupe(Type, &.{new_type, t}) catch unreachable;
                return .{.plural = ts};
            },
            .plural => |ts| {
                const new_ts = arena.alloc(Type, ts.len + 1) catch unreachable;
                new_ts[0] = new_type;
                for (new_ts[1..], ts) |*new_t, t| {
                    new_t.* = t;
                }
                return .{.plural = new_ts};
            }
        }
    }
    pub fn ptr(arena: std.mem.Allocator, sub_type: TypeExpr) TypeExpr {
        return prefixWith(arena, sub_type, .ptr);
    }
    // assume sub type is a ptr
    pub fn deref(sub_type: TypeExpr) TypeExpr {
        const ts = sub_type.plural[1..];
        return if (ts.len > 1) TypeExpr {.plural = ts} else TypeExpr {.singular = ts[0]};
    }
    pub fn first(self: TypeExpr) Type {
        return switch (self) {
            .singular => |t| t,
            .plural => |ts| ts[0],
        };
    }
    pub fn isType(self: TypeExpr, other: Type, env: TypeEnv) bool {
        return switch (self) {
            .singular => |t| t.eq(other, env),
            .plural => false,
        };
    }
    pub fn fromEnv(self: TypeExpr, env: TypeEnv) ?TypeExpr {
        const first_t = self.first();
        return if (first_t == .iden) env.get(first_t.iden) orelse null else self;
    }
    pub fn eq(self: TypeExpr, other: TypeExpr, env: TypeEnv) bool {
        return switch (self) {
            .singular => |t1| switch (other) {
                .singular => |t2| t1.eq(t2, env),
                .plural => false,
            },
            .plural => |t1| switch (other) {
                .singular => false,
                .plural => |t2| t1.len == t2.len and for (t1, t2) |sub_t1, sub_t2| {
                    if (!sub_t1.eq(sub_t2, env)) break false;
                } else true,
            }
        };
    }
    pub fn format(value: TypeExpr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {

        switch (value) {
            .singular => |t| _ = try writer.print("{}", .{t}),
            .plural => |ts| for (ts) |t| {
                _ = try writer.print("{}", .{t});
            },
        }
    }
};