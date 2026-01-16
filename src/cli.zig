const std = @import("std");

pub const Error = error {
    ExpectMoreArg,
    DuplicateArg,
    InvalidOption,
};

pub const ArgParser = struct {
    a: std.mem.Allocator = undefined,
   
    commands: std.SegmentedList(Command, 1) = undefined,
    root_command: *Command = undefined,

    pub fn init(self: *ArgParser, a: std.mem.Allocator, pgm_name: []const u8, desc: []const u8) void {
        self.commands = .{};
        self.commands.append(a, .{.root = self, .desc = desc, .name = pgm_name}) catch unreachable;
        self.a = a;
        self.root_command = self.commands.at(0);
    }

    pub fn Maybe(comptime T: type) type {
        return union(enum) {
            none,
            just: *const T,
        };
    }

    pub const Command = struct {
        root: *ArgParser,
        prefix_args: std.StringHashMapUnmanaged(Parse) = .{},
        postional_args: std.ArrayListUnmanaged(Parse) = .{},

        positional_ct: u32 = 0,

        sub_commands: std.StringArrayHashMapUnmanaged(*Command) = .{},
        name: []const u8,
        desc: []const u8,
        occur: bool = false,

        

        pub fn add_opt(
            self: *Command,
            comptime T: type, ref: *T,
            default: Maybe(T),
            arg_ty: ArgType,
            meta_var_name: []const u8,
            desc: []const u8) *Command {
            const a = self.root.a;
            const d: ?Default = switch (default) {
                .none => null,
                .just => |val| Default{.ptr = @ptrCast(val), .size = @sizeOf(T)},
            };
            const p = Parse {
                .f = gen_parse(T), 
                .ptr = @ptrCast(ref),
                .default = d,
                .meta_var_name = meta_var_name,
                .pure_flag = T == bool,
                .desc = desc
            };
            switch (arg_ty) {
                .prefix => |prefix| 
                    if (self.prefix_args.fetchPut(a, prefix, p) catch unreachable) |_| {
                        std.process.fatal("prefix arg `{s} {s}`already exists", .{prefix, p.meta_var_name});
                    },
                .positional => self.postional_args.append(a, p) catch unreachable,
            }
            return self;
        }

        pub fn sub_command(self: *Command, name: []const u8, desc: []const u8) *Command {
            self.root.commands.append(self.root.a, .{.name = name, .desc = desc, .root = self.root}) catch unreachable;
            const gop = self.sub_commands.getOrPut(self.root.a, name) catch unreachable;
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = self.root.commands.at(self.root.commands.count() - 1);
            return gop.value_ptr.*;
        }

        // TODO: this assumes the first arg, the name of the executable itself, is already next'ed.
        pub fn parse(self: *Command, args: *std.process.ArgIterator) !void {
            self.occur = true;
            while (args.next()) |raw_arg| {
                if (self.sub_commands.getPtr(raw_arg)) |command| {
                    self.occur = false;
                    return try command.*.parse(args);
                }
                else if (self.prefix_args.getPtr(raw_arg)) |p| {

                    if (p.occurence > 0) {
                        std.log.err("option `{s} {s}` already occured", .{raw_arg, p.meta_var_name});
                        return Error.DuplicateArg;
                    }
                    p.occurence += 1;
                    if (p.pure_flag) {
                        @as(*bool, @alignCast(@ptrCast(p.ptr))).* = true;
                        continue;
                    }
                    const next = args.next() orelse {
                        std.log.err("expect `{s}` after `{s}`", .{p.meta_var_name, raw_arg});
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
            var map_it = self.prefix_args.iterator();
            while (map_it.next()) |kv| {
                if (kv.value_ptr.occurence == 0) {
                    if (kv.value_ptr.default) |default| {
                        const bytes_dst: []u8 = @as([*]u8, @ptrCast(kv.value_ptr.ptr))[0..default.size];
                        const bytes_src: []const u8 = @as([*]const u8, @ptrCast(default.ptr))[0..default.size];
                        @memcpy(bytes_dst, bytes_src);
                    } else {
                        std.log.err("missing option: `{s} {s}`", .{kv.key_ptr.*, kv.value_ptr.meta_var_name});
                        return Error.ExpectMoreArg;
                    }
                }
            }
            for (self.postional_args.items) |p| {
                if (p.occurence == 0) {
                    if (p.default) |default| {
                        const bytes_dst: []u8 = @as([*]u8, @ptrCast(p.ptr))[0..default.size];
                        const bytes_src: []const u8 = @as([*]const u8, @ptrCast(default.ptr))[0..default.size];
                        @memcpy(bytes_dst, bytes_src);
                    } else {
                        std.log.err("missing positional argument `{s}`", .{p.meta_var_name});
                        return Error.ExpectMoreArg;
                    }
                }
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
                    print("\t{s} -- {s}\n", .{sub.key_ptr.*, sub.value_ptr.*.desc});
                } 
                print("\t<sub-command> --help\tprint help of a particular subcommand\n\n", .{});
            }

            for (self.postional_args.items) |positional| {
                print("\t{s}\t{s}\n", .{positional.meta_var_name, positional.desc});
            }
            var it = self.prefix_args.iterator();
            while (it.next()) |entry| {
                const p = entry.value_ptr;
                print("\t{s} {s}\t{s}\n", .{entry.key_ptr.*, p.meta_var_name, p.desc});
            }
            print("\t--help\tprint this help message\n", .{});
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

    pub fn add_opt(
        self: *ArgParser,
        comptime T: type, ref: *T,
        default: Maybe(T),
        arg_ty: ArgType,
        meta_var_name: []const u8,
        desc: []const u8) *Command {

        return self.root_command.add_opt(T, ref, default, arg_ty, meta_var_name, desc);
    }

    pub fn sub_command(self: *ArgParser, name: []const u8, desc: []const u8) *Command {
        return self.root_command.sub_command(name, desc);
    }

    pub fn gen_parse(comptime T: type) *const ParseFn {
        const info = @typeInfo(T);
        return switch(info) {
            .float => parse_f32,
            .@"enum" => gen_parse_enum(T),
            .bool => undefined, // never used
            .int => gen_parse_int(T),
            .optional => |optional| struct {
                pub fn f(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
                    const inner_f = gen_parse(optional.child);
                    var inner: optional.child = undefined;
                    if (!inner_f(raw_arg, @ptrCast(&inner))) return false;
                    @as(*?optional.child, @alignCast(@ptrCast(ptr))).* = inner;
                    return true;
                }
            }.f,
            else => 
                if (T == []const u8)
                    parse_str
                else if (T == [:0]const u8)
                    parse_strz
                else
                    @compileError("Unsupported opt type " ++ @typeName(T)),
                };
    }

    fn parse_str(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*[]const u8, @alignCast(@ptrCast(ptr))).* = raw_arg;
        return true;
    }

    fn parse_strz(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*[:0]const u8, @alignCast(@ptrCast(ptr))).* = raw_arg;
        return true;
    }

    fn parse_f32(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
        @as(*f32, @alignCast(@ptrCast(ptr))).* = std.fmt.parseFloat(f32, raw_arg) catch |e| {
            std.log.err("expect float, got {}", .{e});
            return false;
        };
        return true;
    }

    fn gen_parse_int(comptime T: type) *const ParseFn {
        return struct {
            pub fn f(raw_arg: [:0]const u8, ptr: *anyopaque) bool {
                @as(*T, @alignCast(@ptrCast(ptr))).* = std.fmt.parseInt(T, raw_arg, 10) catch return false;
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
                        @as(*T, @alignCast(@ptrCast(ptr))).* = @enumFromInt(i);
                        return true;
                    }
                }
                std.log.err("expect one of {s}, got {s}", .{comptime enum_desc(T), raw_arg});
                return false;
            }
        }.f;
    }

    pub fn print_help(self: *ArgParser) void {
        self.root_command.print_help();
    }

    pub fn parse(self: *ArgParser, args: *std.process.ArgIterator) !void {
        return self.root_command.parse(args);
    }


    pub fn deinit(self: *ArgParser) void {
        self.root_command.deinit(self.a);
        self.commands.deinit(self.a);
    }
};

fn enum_desc_len(comptime E: type) usize {
    const fields = @typeInfo(E).@"enum".fields;
    if (fields.len == 0) return 0;
    var len: usize = 0;
    inline for (fields) |field| {
        len += field.name.len;
    }
    len += fields.len - 1;
    return len;
}

pub fn enum_desc(comptime E: type) []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    if (fields.len == 0) return "";
    var desc: []const u8 = fields[0].name;
    inline for (fields[1..]) |field| {
        desc = desc ++ "|";
        desc = desc ++ field.name;
    }
    return desc;

}

// pub const ErrorReturnCode = enum(u8) {
//     success = 0,
//     cli,
//     lex,
//     parse,
//     sema,
//     eval,
//     mem_leak,
//     unexpected,
// 
//     pub fn from_err(e: anyerror) ErrorReturnCode {
//         if (is_err_from_set(Error, e)) return .cli;
//         if (is_err_from_set(Lexer.Error, e)) return .lex;
//         if (is_err_from_set(Parser.Error, e)) return .parse;
//         if (is_err_from_set(Sema.Error, e)) return .sema;
//         //if (is_err_from_set(e, Eval.Error)) return .lex;S
//         return .unexpected;
//     }
// 
//     pub fn is_err_from_set(comptime T: type, e: anyerror) bool {
//         const err_info = @typeInfo(T).error_set.?;
//         return inline for (err_info) |err| {
//             if (@field(T, err.name) == e) break true;
//         } else false;
//     }
// };

// pub const CompileStage = enum {
//     lex,
//     parse,
//     sema,
//     play,
// };
