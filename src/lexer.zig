const std = @import("std");
const assert = std.debug.assert;
const log = @import("log.zig");
const InternPool = @import("intern_pool.zig");
pub const Symbol = InternPool.Symbol;
// FIXME
// Token and Loc is super inefficient
// The `Token` in the Zig compiler only stores an offset and the type of the token.
// The Location can then be recalculated with the token with the offset
// likewise, the Data of the token

pub const Loc = struct {
    row: u32,
    col: u32,
    path: []const u8,
    pub fn format(value: Loc, writer: *std.Io.Writer) !void {
        return writer.print("{s}:{}:{}", .{ value.path, value.row, value.col });
    }
};

pub const Token = struct {
    tag: TokenType,
    off: u32,

    pub fn fmt(token: Token, lexer: *const Lexer) TokenFmt {
        return .{ .token = token, .lexer = lexer };
    }

    // pub fn format(self: Token, writer: *std.Io.Writer) !void {
    //     return self.tag.format(writer);
    // }
};

pub const TokenFmt = struct {
    token: Token,
    lexer: *const Lexer,

    pub fn format(self: TokenFmt, writer: *std.Io.Writer) !void {
        const str = token_string.get(self.token.tag) orelse switch (self.token.tag) {
            .iden => return writer.print("identifier `{s}`", .{ self.lexer.reIdentifierStr(self.token.off) }),
            .string => return writer.print("string literal \"{s}\"", .{ self.lexer.reStringLitStr(self.token.off) }),
            .int => return writer.print("integer literal `{s}`", .{ self.lexer.reIntStr(self.token.off) }),
            .float => return writer.print("float literal `{s}`", .{ self.lexer.reFloatStr(self.token.off) }),
            .eof => return writer.writeAll("<eof>"),
            else => unreachable,
        };
        return writer.print("`{s}`", .{ str });
    }
};

pub fn to_loc_src(src: []const u8, path: []const u8, off: u32) Loc {
    var i: u32 = 0;
    var res = Loc{ .row = 1, .col = 1, .path = path };
    while (i < off) : (i += 1) {
        const c = src[i];
        switch (c) {
            '\n', '\r' => {
                res.row += 1;
                res.col = 1;
            },
            else => res.col += 1,
        }
    }
    return res;
}

pub fn to_loc(lexer: Lexer, off: u32) Loc {
    return to_loc_src(lexer.src, lexer.path, off);
}

pub const TokenType = enum {
    lparen,
    rparen,
    lbrack,
    rbrack,
    lcurly,
    rcurly,
    semi,
    colon,
    assign,
    comma,
    dot,
    ampersand,
    not,
    arrow,

    plus,
    minus,
    times,
    div,
    mod,

    eq,
    lt,
    gt,

    true,
    false,
    proc,
    @"fn",
    import,
    let,
    ret,
    as,
    @"if",
    @"else",
    loop,
    type,
    foreign,
    subset,

    iden,
    // print,
    string,
    int,
    float,

    eof,

    pub fn format(self: TokenType, writer: *std.Io.Writer) !void {
        const str = token_string.get(self) orelse @tagName(self);
        return writer.print("`{s}`", .{ str });
    }
};

const token_string = std.EnumArray(TokenType, ?[]const u8).init(.{
    .lparen = "(",
    .rparen = ")",
    .lbrack = "[",
    .rbrack = "]",
    .lcurly = "{",
    .rcurly = "}",
    .semi = ";",
    .colon = ":",
    .assign = "=",
    .comma = ",",
    .dot = ".",
    .ampersand = "&",
    .not = "!",
    .plus = "+",
    .minus = "-",
    .times =  "*",
    .div = "/",
    .mod = "%",
    .lt = "<",
    .gt = ">",

    .arrow = "->",
    .eq = "==",

    .true = "true",
    .false = "false",
    .proc = "proc",
    .@"fn" = "fn",
    .import = "import",
    .let = "let",
    .ret = "ret",
    .as = "as",
    .@"if" = "if",
    .@"else" = "else",
    .loop = "loop",
    .type = "type",
    .foreign = "foreign",
    .subset = "subset",
    .iden = null,
    .string = null,
    .int = null,
    .float = null,

    .eof = null,
});

const single_char_punc: [std.math.maxInt(u8)]?TokenType = blk: {
    const es = @typeInfo(TokenType).@"enum".fields;
    var arr: [std.math.maxInt(u8)]?TokenType = undefined;
    @memset(&arr, null);
    for (es) |e| {
        const tk: TokenType = @enumFromInt(e.value);
        const str = token_string.get(tk) orelse continue;
        if (str.len == 1) arr[str[0]] = tk;
    }
    break :blk arr;
};

const multi_char_punc = blk: {
    const es = @typeInfo(TokenType).@"enum".fields;
    var keywords: []const struct { []const u8, TokenType } = &.{};
    outer: for (es) |e| {
        const tk: TokenType = @enumFromInt(e.value);
        const str = token_string.get(tk) orelse continue;
        if (str.len == 1) continue;
        for (str) |c| if (std.ascii.isAlphabetic(c)) continue :outer;
        keywords = keywords ++ .{ .{ str, tk} };
    }
    break :blk keywords;
};

const keywords_map: std.StaticStringMap(TokenType) = blk: {
    const es = @typeInfo(TokenType).@"enum".fields;
    var keywords: []const struct { []const u8, TokenType } = &.{};
    outer: for (es) |e| {
        const tk: TokenType = @enumFromInt(e.value);
        const str = token_string.get(tk) orelse continue;
        if (str.len == 1) continue;
        for (str) |c| if (!std.ascii.isAlphabetic(c)) continue :outer;
        keywords = keywords ++ .{ .{str, tk} };
    }
    break :blk std.StaticStringMap(TokenType).initComptime(keywords);
};




pub const Error = error{ InvalidString, InvalidNum, Unrecognized };
const Lexer = @This();
/// Lexer return either LexerError!?Token.
/// A error indicates the a critical error and the lexing could not be continue.
/// A null indicates the current lexing failed and other lexing should be tried
pub var string_pool: InternPool.StringInternPool = undefined;
pub fn lookup(s: Symbol) []const u8 {
    return string_pool.lookup(s);
}
pub fn intern(s: []const u8) Symbol {
    return string_pool.intern(s);
}
src: []const u8,
path: []const u8,
off: u32 = 0,
peekbuf: ?Token = null,

pub var int: Symbol = undefined;
pub var float: Symbol = undefined;
pub var double: Symbol = undefined;
pub var @"void": Symbol = undefined;
pub var @"bool": Symbol = undefined;
pub var char: Symbol = undefined;
pub var main: Symbol = undefined;
pub var len: Symbol = undefined;
pub var printf: Symbol = undefined;

pub fn init(src: []const u8, path: []const u8) Lexer {
    int = string_pool.intern("int");
    float = string_pool.intern("float");
    double = string_pool.intern("double");
    @"void" = string_pool.intern("void");
    @"bool" = string_pool.intern("bool");
    char = string_pool.intern("char");
    main = string_pool.intern("main");
    len = string_pool.intern("len");
    printf = string_pool.intern("printf");
    return Lexer{ .src = src, .path = path };
}

fn skipWs(self: *Lexer) void {
    while (self.off < self.src.len) : (self.off += 1) {
        self.skipComment();
        const c = self.src[self.off];
        if (!std.ascii.isWhitespace(c)) {
            break;
        }
    }
}

fn skipComment(self: *Lexer) void {
    if (self.off < self.src.len - 1 and self.src[self.off] == '/' and self.src[self.off + 1] == '/') {
        while (self.off < self.src.len) : (self.off += 1) {
            if (self.src[self.off] == '\n') {
                self.off += 1;
                break;
            }
        }
        // runs out of character
    }
}

pub fn nextChar(self: *Lexer) ?u8 {
    if (self.off >= self.src.len) return null;

    defer {
        self.off += 1;
    }
    return self.src[self.off];
}

pub fn rewindChar2(self: *Lexer) void {
    self.off -= 2;
}

pub fn matchSingleLexeme(self: *Lexer) ?Token {
    
    return Token {
        .tag =  single_char_punc[self.nextChar().?] orelse {
            self.off -= 1;
            return null;
        },
        .off = self.off,
    };
}

pub fn matchString(self: *Lexer, s: []const u8) bool {
    if (self.src.len < s.len + self.off) return false;
    if (std.mem.eql(u8, s, self.src[self.off .. self.off + s.len])) {
        self.off += @intCast(s.len);
        return true;
    }
    return false;
}

// TODO the actuall keywords should be matched at `matchIdentifiers`
// and `==` should be done seperately
// https://github.com/Tesseract22/catlang/issues/3#issue-2767972002/
pub fn matchManyLexeme(self: *Lexer) ?Token {
    const off = self.off;
    return inline for (multi_char_punc) |k| {
        if (self.matchString(k[0])) break Token{ .tag = k[1], .off = off };
    } else null;
}

pub fn matchNumLit(self: *Lexer) Error!?Token {
    const off = self.off;
    var first = self.nextChar() orelse return null;
    var have_sign = false;
    if (first == '-' or first == '+') {
        first = self.nextChar() orelse {
            self.off -= 1;
            return null;
        };
        have_sign = true;
    }
    if (!std.ascii.isDigit(first)) { // make sure at least one digit
        if (have_sign) self.rewindChar2() else self.off -= 1;
        return null;
    }
    var dot = false;
    while (self.nextChar()) |c| {
        // TODO error if not space or digit
        switch (c) {
            'a'...'z', 'A'...'Z' => return Error.InvalidNum,

            '0'...'9' => {},
            '.' => {
                if (dot) {
                    self.report_err(off, "Mulitple `.` in number literal", .{});
                    return Error.InvalidNum;
                } else {
                    dot = true;
                }
            },
            else => break,
        }
    }
    defer self.off -= 1;
    return if (!dot) Token{ .tag = .int, .off = off } else Token{ .tag = .float, .off = off };
}

pub fn matchStringLit(self: *Lexer) Error!?Token {
    const off = self.off;
    if ((self.nextChar() orelse return null) != '"') {
        self.off -= 1;
        return null;
    }
    // TODO escape character
    while (self.nextChar()) |c| {
        if (c == '"') {
            return Token{ .tag = .string, .off = off };
        }
        if (c == '\\') {
            const nc = self.nextChar() orelse {
                self.report_err(off, "invalid escape sequence", .{});
                return Error.InvalidString;
            };
            switch (nc) {
                'n', 'r', 't', 'b', 'f', 'v', '\\', '\'', '\"', '0' => {},
                else => {
                    self.report_err(off, "invalid escape sequence", .{});
                    return Error.InvalidString;
                }
            }
        }
    }
    self.report_err(off, "Uncloseed `\"`", .{});
    self.report(self.off, .note, "Previous `\"` here", .{});
    return Error.InvalidString;
}

pub fn matchIdentifier(self: *Lexer) ?Token {
    const off = self.off;
    const first = self.nextChar().?;
    switch (first) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => {
            self.off = off;
            return null;
        },
    }

    while (self.nextChar()) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '_', '0'...'9' => {},
            else => {
                self.off -= 1;
                break;
            },
        }
    }
    return Token{ .tag = keywords_map.get(self.src[off..self.off]) orelse .iden, .off = off };
}

pub fn next(self: *Lexer) Error!Token {
    defer self.peekbuf = null;
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.skipWs();
    if (self.src.len <= self.off) return Token{ .tag = .eof, .off = self.off };

    const token =
        (try self.matchNumLit()) orelse
        self.matchManyLexeme() orelse
        self.matchSingleLexeme() orelse
        (try self.matchStringLit()) orelse
        self.matchIdentifier() orelse {
            self.report_err(self.off, "Unrecognized sequence", .{});
            log.note("looking at {c}", .{ self.src[self.off] });
            return Error.Unrecognized;
        };
    return token;
}

pub fn peek(self: *Lexer) Error!Token {
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.peekbuf = try self.next();
    return self.peekbuf.?;
}

pub fn consume(self: *Lexer) void {
    _ = self.next() catch unreachable;
}

pub fn reIntStr(self: Lexer, off: u32) []const u8 {
    // skip the first one
    var i = off + 1;
    while (i < self.src.len) : (i += 1) {
        // TODO error if not space or digit
        switch (self.src[i]) {
            '0'...'9' => {},
            'a'...'z', 'A'...'Z', '.' => unreachable,
            else => break,
        }
    }
    return self.src[off..i];
}

pub fn reInt(self: Lexer, off: u32) isize {
    return std.fmt.parseInt(isize, self.reIntStr(off), 10) catch unreachable;
}

pub fn reFloatStr(self: Lexer, off: u32) []const u8 {
    var i = off + 1;
    var dot = false;
    while (i < self.src.len) : (i += 1) {
        // TODO error if not space or digit
        switch (self.src[i]) {
            '0'...'9' => {},
            'a'...'z', 'A'...'Z' => unreachable,
            '.' => {
                if (dot) {
                    unreachable;
                } else {
                    dot = true;
                }
            },
            else => break,
        }
    }
    return self.src[off..i];
}

pub fn reFloat(self: Lexer, off: u32) f64 {
    return std.fmt.parseFloat(f64, self.reFloatStr(off)) catch unreachable;
}
pub fn reStringLitStr(self: Lexer, off: u32) []const u8 {
    const Static = struct {
        var buf: [256]u8 = undefined;
    };
    var arr = std.ArrayList(u8).initBuffer(&Static.buf);
    if (self.src[off] != '"') unreachable;
    // TODO escape character
    var i: u32 = off + 1;
    while (i < self.src.len) : (i += 1) {
        const c = self.src[i];
        if (c == '"') {
            return arr.items;
        }
        if (c == '\\') {
            i += 1;
            if (i >= self.src.len) unreachable;
            const nc = self.src[i];
            const escaped: u8 = switch (nc) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '\'' => '\'',
                '\"' => '\"',
                '0' => 0,
                else => unreachable,
            };
            arr.appendAssumeCapacity(escaped);
        } else
            arr.appendAssumeCapacity(self.src[i]);
    } else unreachable;
}

pub fn reStringLit(self: Lexer, off: u32) Symbol {
    return string_pool.intern(self.reStringLitStr(off));
}

pub fn reIdentifier(self: Lexer, off: u32) Symbol {
    return string_pool.intern(self.reIdentifierStr(off));
}

pub fn reIdentifierStr(self: Lexer, off: u32) []const u8 {
    switch (self.src[off]) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => {},
    }
    var i: u32 = off + 1;
    while (i < self.src.len) : (i += 1) {
        switch (self.src[i]) {
            'A'...'Z', 'a'...'z', '_', '0'...'9' => {},
            else => break,
        }
    }
    return self.src[off..i];
}

pub fn report(self: Lexer, off: u32, level: log.Level, comptime fmt: []const u8, args: anytype) void {
    const loc_fmt = "{f} " ++ fmt;
    const loc_args = .{self.to_loc(off)} ++ args;
    switch (level) {
        .err => log.err(loc_fmt, loc_args),
        .note => log.note(loc_fmt, loc_args),
        .debug => log.debug(loc_fmt, loc_args),
    }
    print_src_line_off(self.src, off);
}

pub fn report_err(self: Lexer, off: u32, comptime fmt: []const u8, args: anytype) void {
    return self.report(off, .err, fmt, args);
}

pub fn print_src_line_off(src: []const u8, off: u32) void {
    var start: u32 = off;
    var end: u32 = off;
    var tab_ct: u32 = 0;

    while (start > 0): (start -= 1) {
        if (src[start] == '\n' and start != off) {
            start += 1;
            break;
        } else if (src[start] == '\t') tab_ct += 1;
    }

    while (end < src.len): (end += 1) {
        if (src[end] == '\n') {
            break;
        } else if (src[end] == '\t') tab_ct += 1;
    }
    std.debug.print("\t{s}\n", .{src[start..end]});
    highligh_off(tab_ct, off-start);
}

pub fn highligh_off(tab_ct: u32, line_pos: u32) void {
    for (0..tab_ct+1) |_|
        std.debug.print("\t", .{});
    for (0..line_pos-tab_ct) |_| {
        std.debug.print(" ", .{});
    }
    std.debug.print("^\n", .{});
}

pub fn print_src_line_loc(self: Lexer, loc: Loc) void {
    var off: u32 = 0;
    var row: u32 = 1;
    var col: u32 = 1;
    // find the start of row
    while (off < self.src.len): (off += 1) {
        if (row == loc.row) break;
        const c = self.src[off];
        switch (c) {
            '\n' => {
                row += 1;
                col = 1;
            },
            else => col += 1,
        }
    } else unreachable;

    // find the end of row
    const line_start = off;
    while (off < self.src.len): (off += 1) {
        assert(row == loc.row);
        const c = self.src[off];
        switch (c) {
            '\n' => break,
            else => col += 1,
        }
    }
    const line_end = off;

    std.debug.print("{s}", .{ self.src[line_start..line_end] });

    // print the line  
}
