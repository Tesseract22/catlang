const std = @import("std");

pub const Error = error{
    ExpectMoreArg,
    DuplicateArg,
    InvalidOption,
};

pub const ArgParser = struct {
    gpa: std.mem.Allocator = undefined,
    arena_state: std.heap.ArenaAllocator = undefined,
    arena: std.mem.Allocator = undefined,

    root_command: *Command = undefined,

    pub fn init(self: *ArgParser, a: std.mem.Allocator, pgm_name: []const u8, desc: []const u8) void {
        self.gpa = a;
        self.arena_state = .init(a);
        self.arena = self.arena_state.allocator();

        self.root_command = self.arena.create(Command) catch unreachable;
        self.root_command.* = .{ .root = self, .desc = desc, .name = pgm_name };
    }

    pub fn add_opt_global(self: *ArgParser, comptime T: type, ref: *T, default: Command.Maybe(T), arg_ty: ArgType, meta_var_name: []const u8, desc: []const u8) void {
        self.root_command.add_opt_global(T, ref, default, arg_ty, meta_var_name, desc); 
    }

    pub const Command = struct {
        root: *ArgParser,
        prefix_args: std.array_hash_map.String(Parse) = .empty,
        postional_args: std.ArrayList(Parse) = .empty,

        positional_ct: u32 = 0,

        sub_commands: std.array_hash_map.String(*Command) = .{},
        name: []const u8,
        desc: []const u8,
        occur: bool = false,

        pub fn Maybe(comptime T: type) type {
            return union(enum) {
                none,
                just: *const T,
            };
        }

        pub fn add_opt(self: *Command, comptime T: type, ref: *T, default: Maybe(T), arg_ty: ArgType, meta_var_name: []const u8, desc: []const u8) *Command {
            const gpa = self.root.gpa;
            const d: ?Default = switch (default) {
                .none => null,
                .just => |val| Default{ .ptr = @ptrCast(val), .size = @sizeOf(T) },
            };
            const p = Parse{ .f = gen_parse(T), .ptr = @ptrCast(ref), .default = d, .meta_var_name = meta_var_name, .pure_flag = T == bool, .desc = desc };
            switch (arg_ty) {
                .prefix => |prefix| if (self.prefix_args.fetchPut(gpa, prefix, p) catch unreachable) |_| {
                    std.process.fatal("prefix arg `{s} {s}`already exists", .{ prefix, p.meta_var_name });
                },
                .positional => self.postional_args.append(gpa, p) catch unreachable,
            }
            return self;
        }

        pub fn add_opt_global(self: *Command, comptime T: type, ref: *T, default: Maybe(T), arg_ty: ArgType, meta_var_name: []const u8, desc: []const u8) *Command {

            var it = self.sub_commands.iterator();
            _ = self.add_opt(T, ref, default, arg_ty, meta_var_name, desc);
            while (it.next()) |entry| {
                _ = entry.value_ptr.*.add_opt(T, ref, default, arg_ty, meta_var_name, desc);
            }
            return self;
        }

        pub fn sub_command(self: *Command, name: []const u8, desc: []const u8) *Command {
            const new = self.root.arena.create(Command) catch unreachable;
            new.* = .{ .name = name, .desc = desc, .root = self.root };
            const gop = self.sub_commands.getOrPut(self.root.gpa, name) catch unreachable;
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = new;
            return gop.value_ptr.*;
        }

        pub fn parse(self: *Command, args: *std.process.Args.Iterator) !void {
            self.occur = true;
            while (args.next()) |raw_arg| {
                if (self.sub_commands.getPtr(raw_arg)) |command| {
                    self.occur = false;
                    return try command.*.parse(args);
                } else if (self.prefix_args.getPtr(raw_arg)) |p| {
                    if (p.occurence > 0) {
                        std.log.err("option `{s} {s}` already occured", .{ raw_arg, p.meta_var_name });
                        return Error.DuplicateArg;
                    }
                    p.occurence += 1;
                    if (p.pure_flag) {
                        @as(*bool, @ptrCast(@alignCast(p.ptr))).* = true;
                        continue;
                    }
                    const next = args.next() orelse {
                        std.log.err("expect `{s}` after `{s}`", .{ p.meta_var_name, raw_arg });
                        return Error.ExpectMoreArg;
                    };
                    if (!p.f(next, p.ptr)) {
                        return Error.InvalidOption;
                    }
                    continue;
                }
                if (std.mem.eql(u8, raw_arg, "--help")) {
                    self.print_help();
                    std.process.exit(0);
                }
                if (self.positional_ct >= self.postional_args.items.len) {
                    std.log.err("too many positional argument", .{});
                    return Error.InvalidOption;
                }
                const p = &self.postional_args.items[self.positional_ct];
                p.occurence += 1;
                self.positional_ct += 1;
                if (!p.f(raw_arg, p.ptr)) {
                    return Error.InvalidOption;
                }
            }
            var missed_args_idx: ?usize = null;
            for (self.postional_args.items, 0..) |p, i| {
                if (p.occurence == 0) {
                    if (p.default) |default| {
                        const bytes_dst: []u8 = @as([*]u8, @ptrCast(p.ptr))[0..default.size];
                        const bytes_src: []const u8 = @as([*]const u8, @ptrCast(default.ptr))[0..default.size];
                        @memcpy(bytes_dst, bytes_src);
                    } else {
                        missed_args_idx = i;
                    }
                }
            }
            var missed_args_kv: ?std.array_hash_map.String(Parse).Entry = null;
            var map_it = self.prefix_args.iterator();
            while (map_it.next()) |kv| {
                if (kv.value_ptr.occurence == 0) {
                    if (kv.value_ptr.default) |default| {
                        const bytes_dst: []u8 = @as([*]u8, @ptrCast(kv.value_ptr.ptr))[0..default.size];
                        const bytes_src: []const u8 = @as([*]const u8, @ptrCast(default.ptr))[0..default.size];
                        @memcpy(bytes_dst, bytes_src);
                    } else {
                        missed_args_kv = kv;
                    }
                }
            }
            if (missed_args_idx) |idx| {
                const p = self.postional_args.items[idx];
                std.log.err("missing positional argument `{s}`", .{p.meta_var_name});
                return Error.ExpectMoreArg;
            } else if (missed_args_kv) |kv| {
                std.log.err("missing option: `{s} {s}`", .{ kv.key_ptr.*, kv.value_ptr.meta_var_name });
                return Error.ExpectMoreArg;
            }
            
        }

        pub fn print_help(self: *Command) void {
            const print = std.debug.print;

            print("{s}\n\n", .{self.desc});
            print("usage: {s}", .{self.name});
            for (self.postional_args.items) |positional| {
                print(" {s}", .{positional.meta_var_name});
            }

            if (self.sub_commands.count() > 0) {
                print(" <sub-command>", .{});
            }
            print("\n", .{});

            if (self.sub_commands.count() > 0) {
                var sub_it = self.sub_commands.iterator();
                print("list of sub commands:\n", .{});
                while (sub_it.next()) |sub| {
                    print("  {s: <20}{s}\n", .{ sub.key_ptr.*, sub.value_ptr.*.desc });
                }
                print("  <sub-command> --help  print help of a particular subcommand\n\n", .{});
            }

            for (self.postional_args.items) |positional| {
                print("  {s: <30}{s}\n", .{ positional.meta_var_name, positional.desc });
            }
            var it = self.prefix_args.iterator();
            while (it.next()) |entry| {
                const p = entry.value_ptr;
                print("  {s: <10}{s: <20}{s}\n", .{ entry.key_ptr.*, p.meta_var_name, p.desc });
            }
            print("  {s: <20}print this help message\n", .{ "--help" });
        }

        pub fn deinit(self: *Command, a: std.mem.Allocator) void {
            self.postional_args.deinit(a);
            self.prefix_args.deinit(a);
            var it = self.sub_commands.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(a);
            }
            self.sub_commands.deinit(a);
        }
    };

    pub const ArgType = union(enum) {
        positional,
        prefix: []const u8,
    };

    const Default = struct {
        ptr: *const anyopaque,
        size: usize,
    };

    pub const Parse = struct {
        f: *const ParseFn,
        ptr: *anyopaque,
        occurence: u32 = 0,
        default: ?Default,
        meta_var_name: []const u8,
        desc: []const u8,

        pure_flag: bool = false,
    };

    const EnumContext = struct {
        fields: []std.builtin.Type.EnumField,
    };

    const ParseFn = fn ([:0]const u8, *anyopaque) bool;

    pub fn add_opt(self: *ArgParser, comptime T: type, ref: *T, default: Command.Maybe(T), arg_ty: ArgType, meta_var_name: []const u8, desc: []const u8) *Command {
        return self.root_command.add_opt(T, ref, default, arg_ty, meta_var_name, desc);
    }

    pub fn sub_command(self: *ArgParser, name: []const u8, desc: []const u8) *Command {
        return self.root_command.sub_command(name, desc);
    }

    pub fn gen_parse(comptime T: type) *const ParseFn {
        const info = @typeInfo(T);
        return switch (info) {
            .float => parse_f32,
            .@"enum" => gen_parse_enum(T),
            .bool => undefined, // never used
            .int => gen_parse_int(T),
            .optional => |optional| struct {
                pub fn f(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
                    const inner_f = gen_parse(optional.child);
                    var inner: optional.child = undefined;
                    if (!inner_f(raw_arg, @ptrCast(&inner))) return false;
                    @as(*?optional.child, @ptrCast(@alignCast(ptr))).* = inner;
                    return true;
                }
            }.f,
            else => if (T == []const u8)
                parse_str
            else if (T == [:0]const u8)
                parse_strz
            else
                @compileError("Unsupported opt type " ++ @typeName(T)),
        };
    }

    fn parse_str(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*[]const u8, @ptrCast(@alignCast(ptr))).* = raw_arg;
        return true;
    }

    fn parse_strz(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*[:0]const u8, @ptrCast(@alignCast(ptr))).* = raw_arg;
        return true;
    }

    fn parse_f32(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*f32, @ptrCast(@alignCast(ptr))).* = std.fmt.parseFloat(f32, raw_arg) catch |e| {
            std.log.err("expect float, got {}", .{e});
            return false;
        };
        return true;
    }

    fn gen_parse_int(comptime T: type) *const ParseFn {
        return struct {
            pub fn f(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
                @as(*T, @ptrCast(@alignCast(ptr))).* = std.fmt.parseInt(T, raw_arg, 10) catch return false;
                return true;
            }
        }.f;
    }

    fn gen_parse_enum(comptime T: type) *const ParseFn {
        return struct {
            pub fn f(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
                const fields = @typeInfo(T).@"enum".fields;
                inline for (fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, raw_arg)) {
                        @as(*T, @ptrCast(@alignCast(ptr))).* = @enumFromInt(i);
                        return true;
                    }
                }
                return false;
            }
        }.f;
    }

    pub fn print_help(self: *ArgParser) void {
        self.root_command.print_help();
    }

    pub fn parse(self: *ArgParser, args: *std.process.Args.Iterator) !void {
        self.root_command.parse(args) catch |e| {
            self.print_help();
            return e;
        };
    }

    pub fn deinit(self: *ArgParser) void {
        self.root_command.deinit(self.gpa);
        self.arena_state.deinit();
    }
};
