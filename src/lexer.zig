const std = @import("std");
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
    pub fn format(value: Loc, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("{s}:{}:{}", .{ value.path, value.row, value.col });
    }
};  

pub const Token = struct {
    tag: TokenType,
    off: u32,
};

pub fn to_loc(lexer: Lexer, off: u32) Loc {
    var i: u32 = 0;
    var res = Loc {.row = 1, .col = 1, .path = lexer.path};
    while (i < off): (i += 1) {
        const c = lexer.src[i];
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

    plus,
    minus,
    times,
    div,
    mod,

    eq,
    lt,
    gt,

    proc,
    func,
    let,
    ret,
    as,
    @"if",
    @"else",
    loop,

    iden,
    // print,
    string,
    int,
    float,

    eof,
    pub fn format(value: TokenType, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.write(@tagName(value));
    }
};


pub const LexerError = error{InvalidString, InvalidNum, Unrecognized};
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


pub fn init(src: []const u8, path: []const u8) Lexer {
    return Lexer{ .src = src, .path = path };
}
fn skipWs(self: *Lexer) void {
    while (self.off < self.src.len) : (self.off += 1) {
        const c = self.src[self.off];
        if (!std.ascii.isWhitespace(c)) {
            break;
        }
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
        .tag = switch (self.nextChar().?) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbrack,
            ']' => .rbrack,
            ';' => .semi,
            '{' => .lcurly,
            '}' => .rcurly,
            ':' => .colon,
            '=' => .assign,
            ',' => .comma,
            '+' => .plus,
            '-' => .minus,
            '*' => .times,
            '/' => .div,
            '%' => .mod,
            '>' => .gt,
            '<' => .lt,
            '.' => .dot,
            '&' => .ampersand,
            else => {
                self.off -= 1;
                return null;
            },
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
pub fn matchManyLexeme(self: *Lexer) ?Token {
    const off = self.off;
    const keywords = .{
        .{ "proc", TokenType.proc },
        .{ "let", TokenType.let },
        .{ "fn", TokenType.func },
        .{ "ret", TokenType.ret },
        .{ "as", TokenType.as },
        .{ "==", TokenType.eq },
        .{ "if", TokenType.@"if" },
        .{ "else", TokenType.@"else" },
        .{ "loop", TokenType.loop },
        // .{"print", TokenType.print},
    };
    return inline for (keywords) |k| {
        if (self.matchString(k[0])) break Token {.tag = k[1], .off = off };
    } else null;
}
pub fn matchNumLit(self: *Lexer) LexerError!?Token {
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
        if (have_sign) self.rewindChar2()
        else self.off -= 1;
        return null;
    }
    var dot = false;
    while (self.nextChar()) |c| {
        // TODO error if not space or digit
        switch (c) {
            'a'...'z', 'A'...'Z' => return LexerError.InvalidNum,

            '0'...'9' => {},
            '.' => {
                if (dot) {
                    log.err("{} Mulitple `.` in number literal", .{self.to_loc(off)});
                    return LexerError.InvalidNum;
                } else {
                    dot = true;
                }
            },
            else => break,
        }
    }
    defer self.off -= 1;
    return 
        if (!dot) Token { .tag = .int, .off = off } else Token{ .tag = .float, .off = off };
}
pub fn matchStringLit(self: *Lexer) LexerError!?Token {
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
    }
    log.err("{} Uncloseed `\"`", .{self.to_loc(off)});
    log.note("{} Previous `\"` here", .{self.to_loc(self.off)});
    return LexerError.InvalidString;
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
    return Token{ .tag = .iden, .off = off };
}
pub fn next(self: *Lexer) LexerError!Token {
    defer self.peekbuf = null;
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.skipWs();
    if (self.src.len <= self.off) return Token {.tag = .eof, .off = self.off };

    const token =
        (try self.matchNumLit()) orelse
        self.matchManyLexeme() orelse
        self.matchSingleLexeme() orelse
        (try self.matchStringLit()) orelse
        self.matchIdentifier() orelse return LexerError.Unrecognized;
    return token;
}
pub fn peek(self: *Lexer) LexerError!Token {
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.peekbuf = try self.next();
    return self.peekbuf.?;
}
pub fn consume(self: *Lexer) void {
    _ = self.next() catch unreachable;
}



pub fn reInt (self: Lexer, off: u32) isize {
    // skip the first one
    var i = off + 1;
    while (i < self.src.len): (i += 1) {
        // TODO error if not space or digit
        switch (self.src[i]) {
            '0'...'9' => {},
            'a'...'z', 'A'...'Z', '.' => unreachable,
            else => break,
        }
    }
    return std.fmt.parseInt(isize, self.src[off .. i], 10) catch unreachable; 
}
pub fn reFloat(self: Lexer, off: u32) f64 {
    var i = off + 1;
    var dot = false;
    while (i < self.src.len): (i += 1) {
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
    return std.fmt.parseFloat(f64, self.src[off .. i]) catch unreachable;
}
pub fn reStringLit(self: Lexer, off: u32) Symbol {
    if (self.src[off] != '"') unreachable;
    // TODO escape character
    var i: u32 = off + 1;
    while (i < self.src.len): (i += 1) {
        if (self.src[i] == '"') {
            return string_pool.intern(self.src[off + 1 .. i]);
        }
    }
    unreachable;
}
pub fn reIdentifier(self: Lexer, off: u32) Symbol {
    switch (self.src[off]) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => unreachable,
    }
    var i: u32 = off + 1;
    while (i < self.src.len): (i += 1) {
        switch (self.src[i]) {
            'A'...'Z', 'a'...'z', '_', '0'...'9' => {},
            else => break,
        }
    }
    return string_pool.intern(self.src[off .. i]);
}
