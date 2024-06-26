const std = @import("std");
const log = @import("log.zig");
pub const Loc = struct {
    row: usize,
    col: usize,
    path: []const u8,
    pub fn nextRow(self: *Loc) void {
        self.row += 1;
        self.col = 1;
    }
    pub fn nextCol(self: *Loc) void {
        self.col += 1;
    }
    pub fn format(value: Loc, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("{s}:{}:{}", .{ value.path, value.row, value.col });
    }
};
pub const Token = struct {
    data: TokenData,
    loc: Loc,
};
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
pub const TokenData = union(TokenType) {
    // single char
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

    iden: []const u8,
    // print,
    string: []const u8,
    int: isize,
    float: f64,

    eof,
    pub fn format(value: TokenData, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {

            .iden => |s| {
                _ = try writer.write("iden ");
                _ = try writer.write(s);
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .int => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{}", .{f}),
            else => _ = try writer.write(@tagName(value)),
        }
    }
};

pub const LexerError = error{InvalidString, InvalidNum, Unrecognized};
const Lexer = @This();
/// Lexer return either LexerError!?Token.
/// A error indicates the a critical error and the lexing could not be continue.
/// A null indicates the current lexing failed and other lexing should be tried
src: []const u8,
loc: Loc,
off: usize = 0,
peekbuf: ?Token = null,
pub fn init(src: []const u8, path: []const u8) Lexer {
    return Lexer{ .src = src, .loc = .{ .row = 1, .col = 1, .path = path } };
}
fn skipWs(self: *Lexer) void {
    while (self.off < self.src.len) : (self.off += 1) {
        const c = self.src[self.off];
        if (c == '\n') {
            self.loc.nextRow();
        } else if (c == ' ' or c == '\t') {
            self.loc.nextCol();
        } else {
            break;
        }
    }
}
pub fn nextChar(self: *Lexer) ?u8 {

    if (self.off >= self.src.len) return null;
    defer {
        self.off += 1;
        self.loc.col += 1;
    }
    return self.src[self.off];
}
pub fn rewindChar(self: *Lexer) void {
    self.off -= 1;
    self.loc.col -= 1;
}
pub fn rewindChar2(self: *Lexer) void {
    self.off -= 2;
    self.loc.col -= 2;
}
pub fn matchSingleLexeme(self: *Lexer) ?TokenData {

    return switch (self.nextChar().?) {
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
            self.rewindChar();
            return null;
        },
    };
}
pub fn matchString(self: *Lexer, s: []const u8) bool {
    if (self.src.len < s.len + self.off) return false;
    if (std.mem.eql(u8, s, self.src[self.off .. self.off + s.len])) {
        self.off += s.len;
        self.loc.col += s.len;
        return true;
    }
    return false;
}
pub fn matchManyLexeme(self: *Lexer) ?TokenData {
    const keywords = .{
        .{ "proc", TokenData.proc },
        .{ "let", TokenData.let },
        .{ "fn", TokenData.func },
        .{ "ret", TokenData.ret },
        .{ "as", TokenData.as },
        .{ "==", TokenData.eq },
        .{ "if", TokenData.@"if" },
        .{ "else", TokenData.@"else" },
        .{ "loop", TokenData.loop },
        // .{"print", TokenData.print},
    };
    return inline for (keywords) |k| {
        if (self.matchString(k[0])) break k[1];
    } else null;
}
/// Only supports decimal for now
pub fn matchNumLit(self: *Lexer) LexerError!?TokenData {
    const off = self.off;
    var first = self.nextChar() orelse return null;
    var have_sign = false;
    if (first == '-' or first == '+') {
        first = self.nextChar() orelse {
            self.rewindChar();
            return null;
        };
        have_sign = true;
    }
    if (!std.ascii.isDigit(first)) { // make sure at least one digit
        if (have_sign) self.rewindChar2()
        else self.rewindChar();
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
                    log.err("{} Mulitple `.` in number literal", .{self.loc});
                    return LexerError.InvalidNum;
                } else {
                    dot = true;
                }
            },
            else => break,
        }
    }
    defer self.rewindChar();
    return if (!dot) TokenData{ .int = std.fmt.parseInt(isize, self.src[off .. self.off - 1], 10) catch unreachable } else TokenData{ .float = std.fmt.parseFloat(f64, self.src[off .. self.off - 1]) catch unreachable };
}
pub fn matchStringLit(self: *Lexer) LexerError!?TokenData {
    const off = self.off;
    const loc = self.loc;
    if ((self.nextChar() orelse return null) != '"') {
        self.rewindChar();
        return null;
    }
    // TODO escape character
    while (self.nextChar()) |c| {
        if (c == '"') {
            return TokenData{ .string = self.src[off + 1 .. self.off - 1] };
        }
    }
    log.err("{} Uncloseed `\"`", .{self.loc});
    log.note("{} Previous `\"` here", .{loc});
    return LexerError.InvalidString;
}
pub fn matchIdentifier(self: *Lexer) ?TokenData {
    const off = self.off;
    const col = self.loc.col;
    const first = self.nextChar().?;
    switch (first) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => {
            self.off = off;
            self.loc.col = col;
            return null;
        },
    }

    while (self.nextChar()) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '_', '0'...'9' => {},
            else => {
                self.rewindChar();
                break;
            },
        }
    }
    return TokenData{ .iden = self.src[off..self.off] };
}
pub fn next(self: *Lexer) LexerError!Token {
    defer self.peekbuf = null;
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.skipWs();
    if (self.src.len <= self.off) return Token {.data = .eof, .loc = self.loc };

    const token_data =
        (try self.matchNumLit()) orelse
        self.matchManyLexeme() orelse
        self.matchSingleLexeme() orelse
        (try self.matchStringLit()) orelse


    self.matchIdentifier() orelse return LexerError.Unrecognized;
    
    return Token{ .data = token_data, .loc = self.loc };
}
pub fn peek(self: *Lexer) LexerError!Token {
    if (self.peekbuf) |peekbuf| return peekbuf;
    self.peekbuf = try self.next();
    return self.peekbuf.?;
}
pub fn consume(self: *Lexer) void {
    _ = self.next() catch unreachable;
}
