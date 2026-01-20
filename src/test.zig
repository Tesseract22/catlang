const driver = @import("main.zig");
const std = @import("std");
const log = @import("log.zig");
const cli = @import("cli.zig");

const TTY = std.io.tty.Config;
const Child = std.process.Child;

const Opt = struct {
    var test_path: []const u8 = undefined;
    var catc_path: []const u8 = undefined;
    var out_path: []const u8 = undefined;
};

const RunProgramResult = (Child.SpawnError || std.Io.Reader.LimitedAllocError)!Child.Term;

const MatchResult = enum {
    match,
    mismatch,
    unexpected,
};

const TestResult = struct {
    path: []const u8,  
    compiler_status: driver.ErrorReturnCode,
    program_status: RunProgramResult,
    stderr_content: []const u8,
    match_result: MatchResult,
    // diagnostic: []const u8,
};

const TestResults = std.ArrayList(TestResult);

var enable_color = false;

pub fn main() !void {
    log.init();
    const stdout_raw = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    var stdout_writer = stdout_raw.writer(&buf);
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch unreachable;
    const tty = TTY.detect(stdout_raw);

    enable_color = stdout_raw.getOrEnableAnsiEscapeSupport();
    var all_success = true;

    //
    // Allocator set up
    //
    var gpa_back = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa_back.deinit();
    const gpa = gpa_back.allocator();

    var arena_back = std.heap.ArenaAllocator.init(gpa);
    defer arena_back.deinit();
    const arena = arena_back.allocator();

    // CLI args
    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();

    var arg_parser = cli.ArgParser {};
    arg_parser.init(gpa, args.next().?, "Catlang Test Suite");
    _ = arg_parser
        .add_opt([]const u8, &Opt.catc_path, .none, .positional, "<catc-path>", "the path to the Catlang compiler")
        .add_opt([]const u8, &Opt.test_path, .none, .positional, "<test-path>", "the path to the test directory")
        .add_opt([]const u8, &Opt.out_path, .none, .positional, "<out-path>", "the path to the output directory");
   
    try arg_parser.parse(&args);

    var test_results = TestResults.empty;
    
    var test_dir = std.fs.cwd().openDir(Opt.test_path, .{ .iterate = true }) catch |e| {
        log.err("cannot open test direcotyr `{s}`", .{ Opt.test_path });
        return e;
    };
    defer test_dir.close();

    var it = test_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            log.err("unexpected entry in test directory `{s}` has kind `{}`", .{ entry.name, entry.kind });
            continue;
        }
        const ext = std.fs.path.extension(entry.name);
        const stem = std.fs.path.stem(entry.name);
        const full_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ Opt.test_path, entry.name }) catch @panic("OOM");
        const output_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ Opt.out_path, stem }) catch @panic("OOM");


        if (std.mem.eql(u8, ext, ".cat")) {
            var catc = Child.init(&.{ Opt.catc_path, "--mode", "compile", full_path, "-o", output_path, }, arena);
            log.note("output: {s}", .{ output_path });
            const compiler_return: driver.ErrorReturnCode = if (catc.spawnAndWait()) |catc_term|
                switch (catc_term) {
                    .Exited => |exit_code| std.enums.fromInt(driver.ErrorReturnCode, exit_code) orelse .unexpected,
                    else => .unexpected,
                }
            else |e| blk: {
                log.err("{}: failed execute {s}", .{ e, full_path });
                break :blk .unexpected;
            };
            // log.note("output: {s}", .{ output_path });
            const program_term: RunProgramResult, const stdout_content: []const u8, const stderr_content = program: {
                var program = Child.init(&.{ output_path }, arena);
                program.stdout_behavior = .Pipe;
                program.stderr_behavior = .Pipe;
                program.spawn() catch |e| break :program .{ e, "", "" };

                var reader_buf: [256]u8 = undefined;

                var stdout_reader = program.stdout.?.reader(&reader_buf);
                const stdout_content = stdout_reader.interface.allocRemaining(gpa, .unlimited) catch |e| break :program .{ e, "", "" };

                var stderr_reader = program.stderr.?.reader(&reader_buf);
                const stderr_content = stderr_reader.interface.allocRemaining(gpa, .unlimited) catch |e| break :program .{ e, "", "" };

                break :program .{ program.wait(), stdout_content, stderr_content };
            };
            const match_result: MatchResult = match: {
                const output_file_path = std.fmt.allocPrint(arena, "{s}.out", .{ entry.name }) catch @panic("OOM");
                const output_file = test_dir.openFile(output_file_path, .{}) catch |e| {
                    log.err("cannot open output file `{s}`: {}", .{ output_file_path, e });
                    break :match .unexpected;
                };
                const output_content = output_file.readToEndAlloc(arena, 1024*1024) catch |e| {
                    log.err("cannot read output file `{s}`: {}", .{ output_file_path, e });
                    break :match .unexpected;
                };
                break :match if (std.mem.eql(u8, output_content, stdout_content)) .match else .mismatch;
            };
            test_results.append(gpa, 
                .{ 
                    .path = full_path,
                    .compiler_status = compiler_return,
                    .program_status = program_term,
                    .stderr_content = stderr_content,
                    .match_result = match_result,
                }) catch @panic("OOM");
        }

    }

    stdout.print("\n\n--- Overview ---\n\n", .{}) catch unreachable;
    stdout.print("total tests run: {}\n\n", .{test_results.items.len}) catch unreachable;
    stdout.print("{s: <60}{s: <20}{s: <10}{s: <10}\n", .{ "path", "compilation", "run", "stdout" }) catch unreachable;
    for (test_results.items) |result| {
        stdout.print("{s: <60}", .{result.path}) catch unreachable;
        if (result.compiler_status == .success) {
            tty.setColor(stdout, .green) catch unreachable;
            stdout.print("{s: <20}", .{"success"}) catch unreachable;
            tty.setColor(stdout, .reset) catch unreachable;
        } else {
            all_success = false;
            tty.setColor(stdout, .red) catch unreachable;
            stdout.print("{s: <20}", .{@tagName(result.compiler_status)}) catch unreachable;
            tty.setColor(stdout, .reset) catch unreachable;
        }
        if (result.program_status) |status|
            switch (status) {
                .Exited => |code| 
                    if (code == 0) {
                        tty.setColor(stdout, .green) catch unreachable;
                        stdout.print("{s: <10}", .{ "success" }) catch unreachable;
                        tty.setColor(stdout, .reset) catch unreachable;
                    } else {
                        tty.setColor(stdout, .red) catch unreachable;
                        stdout.print("{: <10}", .{ code }) catch unreachable;
                        tty.setColor(stdout, .reset) catch unreachable;

                    },
                inline else => |crash| {
                    tty.setColor(stdout, .red) catch unreachable;
                    stdout.print("{s}: {}", .{ @tagName(status), crash }) catch unreachable;
                    tty.setColor(stdout, .reset) catch unreachable;
                }

            }
        else |e|
            stdout.print("{s: <10}", .{ @errorName(e) }) catch unreachable;

        
        tty.setColor(stdout, if (result.match_result == .match) .green else .red) catch unreachable;
        stdout.print("{s: <10}", .{ @tagName(result.match_result)} ) catch unreachable;
        tty.setColor(stdout, .reset) catch unreachable;

        stdout.writeByte('\n') catch unreachable;
    }

    stdout.print("\n\n--- Details ---\n\n", .{}) catch unreachable;
    for (test_results.items) |result| {
        if (result.stderr_content.len == 0) continue;
        stdout.print("{s}:\n", .{result.path}) catch unreachable;
        stdout.print("{s}\n", .{result.stderr_content}) catch unreachable;
    }
}
