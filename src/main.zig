const std = @import("std");
const types = @import("./types.zig");
const pathmod = @import("./path.zig");
const scanner = @import("./scanner.zig");
const output = @import("./output.zig");
const cache = @import("./cache.zig");

const Allocator = std.mem.Allocator;

const CliOptions = struct {
    path: []const u8,
    wait: bool,
    force: bool,
    json: bool,
    verbose: bool,
    cross_mount: bool,
    depth: u8,
    top: u16,
    sessions: bool,
    status: bool,
    kill_pid: ?u32,
    help: bool,
    version: bool,
};

pub fn main() void {
    const exit_code = run() catch |err| switch (err) {
        error.InvalidArgument, error.BadValue => 1,
        else => 1,
    };
    std.process.exit(@as(u8, @intCast(exit_code)));
}

fn run() !u8 {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    var options = parseArgs() catch |err| {
        try printUsage();
        return err;
    };
    if (options.force) options.wait = true;

    if (options.help) {
        try printUsage();
        return 0;
    }

    if (options.version) {
        try stdout.print("zigdu 0.1.0\n", .{});
        return 0;
    }

    if ((@intFromBool(options.sessions) +
        @intFromBool(options.status) +
        @intFromBool(options.kill_pid != null)) > 1)
    {
        try stderr.print("error: --sessions, --status, and --kill are mutually exclusive\n", .{});
        return error.InvalidArgument;
    }

    if ((@intFromBool(options.sessions) +
        @intFromBool(options.status) +
        @intFromBool(options.kill_pid != null)) == 1) {
        return try runSessionCommands(&options);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = types.Config.defaults().validate();
    config.base_dir = try pathmod.expandHome(allocator, config.base_dir);
    config.cache_dir = try pathmod.expandHome(allocator, config.cache_dir);
    config.log_dir = try pathmod.expandHome(allocator, config.log_dir);

    try ensureDir(config.base_dir);
    try ensureDir(config.cache_dir);
    try ensureDir(config.log_dir);

    const expanded_input = try pathmod.expandHome(allocator, options.path);
    defer allocator.free(expanded_input);
    const canonical_path = try pathmod.canonicalize(allocator, expanded_input);
    errdefer allocator.free(canonical_path);
    const hash = try pathmod.hashPath(allocator, canonical_path);

    const depth = if (options.depth == 0) config.default_depth else options.depth;
    const top = if (options.top == 0) config.default_top else options.top;
    const use_cache = (!options.wait and !options.force);

    var result: types.ScanResult = undefined;
    var used_cache = false;
    var had_warnings = false;

    if (use_cache) {
        if (cache.readCache(allocator, canonical_path, hash, config)) |cached| {
            result = cached;
            used_cache = true;
            if (options.verbose) {
                try stderr.print("cache hit: {s}\n", .{hash});
            }
        } else |err| {
            _ = err;
            used_cache = false;
        }
    }

    if (!used_cache) {
        if (options.verbose) {
            try stderr.print("scanning path: {s}\n", .{canonical_path});
        }

        const scan = try scanner.scan(allocator, canonical_path, config, options.cross_mount);
        result = scan.result;
        had_warnings = scan.had_warnings;
        result.cache_timestamp = null;
        if (options.verbose) {
            try stderr.print("scan complete in {} ms\n", .{result.duration_ms});
        }
        cache.writeCache(allocator, hash, &result, config) catch |err| {
            if (options.verbose) {
                try stderr.print("warning: cache write failed ({s})\n", .{@errorName(err)});
            }
        };
    }

    if (used_cache) {
        if (options.verbose) {
            const age = if (result.cache_timestamp) |ts| blk: {
                if (ts <= 0) break :blk 0;
                const now_ts = now();
                break :blk if (ts > @as(i64, @intCast(now_ts))) 0 else now_ts - @as(u64, @intCast(ts));
            } else 0;
            try stderr.print("cache hit age: {d}s\n", .{age});
        }
        had_warnings = false;
        result.cache_timestamp = result.cache_timestamp orelse result.timestamp;
    } else {
        result.cache_timestamp = null;
    }

    if (options.json) {
        try output.formatJson(
            allocator,
            stdout,
            &result,
            depth,
            top,
            result.cache_timestamp,
        );
    } else {
        try output.formatHumanReadable(
            allocator,
            stdout,
            &result,
            depth,
            top,
            result.cache_timestamp,
        );
    }

    return if (had_warnings) 2 else 0;
}

fn runSessionCommands(options: *const CliOptions) !u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (options.sessions) {
        if (options.json) {
            try stdout.writeAll("{\"sessions\":[]}\n");
        } else {
            try stdout.print("no active sessions\n", .{});
        }
        return 0;
    }

    if (options.status) {
        if (options.json) {
            try stdout.writeAll("{\"error\":\"status not implemented\",\"code\":1}\n");
        } else {
            try stderr.print("status command is not implemented\n", .{});
        }
        return 1;
    }

    if (options.kill_pid != null) {
        if (options.json) {
            try stdout.print(
                "{{\"pid\":{},\"path\":\"\",\"status\":\"not_implemented\"}}\n",
                .{options.kill_pid.?},
            );
        } else {
            try stderr.print("kill command is not implemented for pid {}\n", .{options.kill_pid.?});
        }
        return 1;
    }
    return 0;
}

fn parseArgs() !CliOptions {
    var iterator = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer iterator.deinit();

    var opts = CliOptions{
        .path = ".",
        .wait = false,
        .force = false,
        .json = false,
        .verbose = false,
        .cross_mount = false,
        .depth = 0,
        .top = 0,
        .sessions = false,
        .status = false,
        .kill_pid = null,
        .help = false,
        .version = false,
    };

    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, arg, "--wait") or std.mem.eql(u8, arg, "-w")) {
            opts.wait = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--cross-mount")) {
            opts.cross_mount = true;
        } else if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-d")) {
            const raw = iterator.next() orelse return error.InvalidArgument;
            opts.depth = parsePositiveU8(raw) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--top") or std.mem.eql(u8, arg, "-t")) {
            const raw = iterator.next() orelse return error.InvalidArgument;
            opts.top = parsePositiveU16(raw) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "--depth=")) {
            opts.depth = parsePositiveU8(arg[8..]) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "--top=")) {
            opts.top = parsePositiveU16(arg[6..]) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--sessions")) {
            opts.sessions = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            opts.status = true;
        } else if (std.mem.eql(u8, arg, "--kill")) {
            const raw = iterator.next() orelse return error.InvalidArgument;
            opts.kill_pid = std.fmt.parseUnsigned(u32, raw, 10) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "-k")) {
            const raw = if (arg.len > 2) arg[2..] else null;
            const pid_text = raw orelse iterator.next() orelse return error.InvalidArgument;
            if (pid_text.len == 0) return error.InvalidArgument;
            opts.kill_pid = std.fmt.parseUnsigned(u32, pid_text, 10) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArgument;
        } else {
            opts.path = arg;
        }
    }

    return opts;
}

fn parsePositiveU8(value: []const u8) !u8 {
    const parsed = try std.fmt.parseUnsigned(u8, value, 10);
    if (parsed == 0) return error.BadValue;
    return parsed;
}

fn parsePositiveU16(value: []const u8) !u16 {
    const parsed = try std.fmt.parseUnsigned(u16, value, 10);
    if (parsed == 0) return error.BadValue;
    return parsed;
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn now() u64 {
    return @intCast(std.time.timestamp());
}

fn printUsage() !void {
    const out = std.io.getStdOut();
    const writer = out.writer();
    try writer.writeAll(
        \\Usage: zigdu [options] [path]
        \\
        \\Options:
        \\  --wait, -w             wait for scan
        \\  --force, -f            force fresh scan
        \\  --json, -j             JSON output
        \\  --verbose, -v          emit diagnostics
        \\  --cross-mount          cross filesystem boundaries
        \\  --depth, -d <N>        max output depth
        \\  --top, -t <N>          max entries per level
        \\  --sessions             list active sessions
        \\  --status               query status for resolved path
        \\  --kill <PID>           stop background session
        \\  --help                 show usage
        \\  --version              print version
        \\
    );
}
