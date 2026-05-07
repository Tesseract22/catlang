const driver = @import("main.zig");
const std = @import("std");
const fatal = std.process.fatal;
const Io = std.Io;
const Terminal = Io.Terminal;
const log = @import("log.zig");
const cli = @import("cli.zig");

const Child = std.process.Child;

const Opt = struct {
    var test_path: []const u8 = undefined;
    var catc_path: []const u8 = undefined;
    var out_path: []const u8 = undefined;
};

const RunProgramResult = std.process.RunError!Child.Term;

const MatchResult = enum {
    match,
    mismatch,
    unexpected,
};

const TestResult = struct {
    path: []const u8,
    target: []const u8,
    compiler_status: driver.ErrorReturnCode,
    program_status: RunProgramResult,
    stderr_content: []const u8,
    match_result: MatchResult,
    // diagnostic: []const u8,

    pub fn less_than(_: void, a: TestResult, b: TestResult) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }

};

const TestResults = std.ArrayList(TestResult);

var enable_color = false;

fn run_one_test(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, 
    test_dir: Io.Dir,
    compile_src_path: []const u8, compile_dest_path: []const u8, target: []const u8,
    test_results: *TestResults, mtx: *Io.Mutex) Io.Cancelable!void {
    var catc = std.process.spawn(io, .{ .argv = &.{ Opt.catc_path, "--mode", "compile", compile_src_path, "-o", compile_dest_path, "--target", target } })
        catch fatal("cannot spawn compiler: {s}", .{ Opt.catc_path });
    log.note("output: {s}", .{ compile_dest_path});
    const compiler_return: driver.ErrorReturnCode = if (catc.wait(io)) |catc_term|
        switch (catc_term) {
            .exited => |exit_code| std.enums.fromInt(driver.ErrorReturnCode, exit_code) orelse .unexpected,
            else => .unexpected,
        }
    else |e| blk: {
        log.err("{}: failed to execute {s}", .{ e, compile_src_path });
        break :blk .unexpected;
    };
    // log.note("output: {s}", .{ output_path });
    const program_term: RunProgramResult, const stdout_content: []const u8, const stderr_content = program: {
        const program = std.process.run(gpa, io, .{ .argv = &.{ compile_dest_path } })
            catch |e| break :program .{ e, "", "" };

        const stdout_content = program.stdout;

        const stderr_content = program.stderr;

        break :program .{ program.term, stdout_content, stderr_content };
    };
    const match_result: MatchResult = match: {
        const basename = std.fs.path.basename(compile_src_path);
        const output_file_path = std.fmt.allocPrint(arena, "{s}.out", .{ basename }) catch @panic("OOM");
        const output_file = test_dir.openFile(io, output_file_path, .{}) catch |e| {
            log.err("cannot open output file `{s}`: {}", .{ output_file_path, e });
            break :match .unexpected;
        };
        var buf: [64]u8 = undefined;
        var reader = output_file.reader(io, &buf);
        const output_content = reader.interface.allocRemaining(arena, .unlimited) catch |e| {
            log.err("cannot read output file `{s}`: {}", .{ output_file_path, e });
            break :match .unexpected;
        };
        break :match if (std.mem.eql(u8, output_content, stdout_content)) .match else .mismatch;
    };
    gpa.free(stdout_content);
    try mtx.lock(io);
    test_results.append(gpa, 
        .{ 
            .path = compile_src_path,
            .target = target,
            .compiler_status = compiler_return,
            .program_status = program_term,
            .stderr_content = stderr_content,
            .match_result = match_result,
        }) catch @panic("OOM");
    mtx.unlock(io);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    log.init(io);
    const stdout_raw = Io.File.stdout();
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = stdout_raw.writer(io, &stdout_buf);
    var stdout = &stdout_writer.interface;
    defer stdout.flush() catch unreachable;
    const term = Terminal { .mode = try Terminal.Mode.detect(io, stdout_raw, false, false), .writer = stdout };

    enable_color = if (stdout_raw.enableAnsiEscapeCodes(io)) |_| true else |_| false;
    var all_success = true;

    // CLI args
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    var arg_parser = cli.ArgParser {};
    arg_parser.init(gpa, args.next().?, "Catlang Test Suite");
    defer arg_parser.deinit();
    _ = arg_parser
        .add_opt([]const u8, &Opt.catc_path, .none, .positional, "<catc-path>", "the path to the Catlang compiler")
        .add_opt([]const u8, &Opt.test_path, .none, .positional, "<test-path>", "the path to the test directory")
        .add_opt([]const u8, &Opt.out_path, .none, .positional, "<out-path>", "the path to the output directory");
   
    try arg_parser.parse(&args);

    var test_results = TestResults.empty;
    defer test_results.deinit(gpa);
    
    var test_dir = Io.Dir.cwd().openDir(io, Opt.test_path, .{ .iterate = true }) catch |e| {
        log.err("cannot open test direcotyr `{s}`", .{ Opt.test_path });
        return e;
    };
    defer test_dir.close(io);

    var arena_back = std.heap.ArenaAllocator.init(gpa);
    defer arena_back.deinit();
    const arena = arena_back.allocator();
    const available_targets = [_][]const u8 {
        "x86_64-linux",
        // "aarch64-linux",
    };

    var it = test_dir.iterate();
    var group = Io.Group.init;
    var mtx = Io.Mutex.init;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) {
            log.err("unexpected entry in test directory `{s}` has kind `{}`", .{ entry.name, entry.kind });
            continue;
        }
        const ext = std.fs.path.extension(entry.name);
        const stem = std.fs.path.stem(entry.name);
        const full_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ Opt.test_path, entry.name }) catch @panic("OOM");
        const output_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ Opt.out_path, stem }) catch @panic("OOM");


        if (std.mem.eql(u8, ext, ".cat")) {
            for (available_targets) |target| {
                group.async(io, run_one_test, .{ io, gpa, arena, test_dir, full_path, output_path, target, &test_results, &mtx });
            }
        }
    }
    try group.await(io);
    std.mem.sort(TestResult, test_results.items, void{}, TestResult.less_than);

    stdout.print("\n\n--- Overview ---\n\n", .{}) catch unreachable;
    stdout.print("total tests run: {}\n\n", .{test_results.items.len}) catch unreachable;
    stdout.print("{s: <60}{s: <20}{s: <10}{s: <10}\n", .{ "path", "compilation", "run", "stdout" }) catch unreachable;
    for (test_results.items) |result| {
        stdout.print("{s: <60}", .{result.path}) catch unreachable;
        if (result.compiler_status == .success) {
            term.setColor(.green) catch unreachable;
            stdout.print("{s: <20}", .{"success"}) catch unreachable;
            term.setColor(.reset) catch unreachable;
        } else {
            all_success = false;
            term.setColor(.red) catch unreachable;
            stdout.print("{s: <20}", .{@tagName(result.compiler_status)}) catch unreachable;
            term.setColor(.reset) catch unreachable;
        }
        if (result.program_status) |status|
            switch (status) {
                .exited => |code| {
                    if (code == 0) {
                        term.setColor(.green) catch unreachable;
                        stdout.print("{s: <10}", .{ "success" }) catch unreachable;
                    } else {
                        term.setColor(.red) catch unreachable;
                        stdout.print("{: <10}", .{ code }) catch unreachable;

                    }
                    term.setColor(.reset) catch unreachable;
                },
                inline else => |crash| {
                    term.setColor(.red) catch unreachable;
                    stdout.print("{s}: {}", .{ @tagName(status), crash }) catch unreachable;
                    term.setColor(.reset) catch unreachable;
                }

            }
        else |e|
            stdout.print("{s: <10}", .{ @errorName(e) }) catch unreachable;

        
        term.setColor(if (result.match_result == .match) .green else .red) catch unreachable;
        stdout.print("{s: <10}", .{ @tagName(result.match_result)} ) catch unreachable;
        term.setColor(.reset) catch unreachable;

        stdout.writeByte('\n') catch unreachable;
    }

    stdout.print("\n\n--- Details ---\n\n", .{}) catch unreachable;
    for (test_results.items) |result| {
        if (result.stderr_content.len == 0) continue;
        stdout.print("{s}:\n", .{result.path}) catch unreachable;
        stdout.print("{s}\n", .{result.stderr_content}) catch unreachable;

        gpa.free(result.stderr_content);
    }
}
