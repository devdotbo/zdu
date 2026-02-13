const std = @import("std");
const types = @import("./types.zig");
const cache = @import("./cache.zig");
const scanner = @import("./scanner.zig");
const platform = @import("./platform/generic.zig");
const ipc = @import("./ipc.zig");
const output = @import("./output.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("unistd.h");
});

pub fn isDuplicate(
    allocator: Allocator,
    path_hash: []const u8,
    config: types.Config,
) !?u32 {
    const pid_path = try cache.pidFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(pid_path);

    const pid = readPidFile(allocator, pid_path) catch return null;
    if (!isPidAlive(pid)) {
        try cleanupStale(allocator, path_hash, config);
        return null;
    }

    return pid;
}

pub fn spawnBackground(
    path: []const u8,
    path_hash: []const u8,
    config: types.Config,
    _depth: u8,
    _top_n: u16,
    cross_mount: bool,
    _verbose: bool,
    _force: bool,
) !u32 {
    _ = _depth;
    _ = _top_n;
    const verbose = _verbose;
    _ = _force;

    const pid = try std.posix.fork();
    if (pid > 0) return @intCast(pid);
    if (pid < 0) return error.ForkFailed;

    if (c.setsid() < 0) std.process.exit(1);

    backgroundMain(path, path_hash, config, cross_mount, verbose) catch {};
    std.process.exit(0);
}

pub fn cleanupStale(
    allocator: Allocator,
    path_hash: []const u8,
    config: types.Config,
) !void {
    const pid_path = try cache.pidFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(pid_path);

    const sock_path = try cache.sockFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(sock_path);

    std.fs.cwd().deleteFile(pid_path) catch {};
    std.fs.cwd().deleteFile(sock_path) catch {};
}

fn backgroundMain(
    path: []const u8,
    path_hash: []const u8,
    config: types.Config,
    cross_mount: bool,
    verbose: bool,
) !void {
    const child_pid = std.posix.getpid();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const start_time = std.time.timestamp();

    const pid_path = try cache.pidFilePath(allocator, config.cache_dir, path_hash);
    const sock_path = try cache.sockFilePath(allocator, config.cache_dir, path_hash);
    const log_path = try cache.logFilePath(allocator, config.log_dir, path_hash, start_time);
    defer {
        allocator.free(pid_path);
        allocator.free(sock_path);
        allocator.free(log_path);
    }

    var log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true, .read = false, .mode = 0o600 });
    defer log_file.close();
    try redirectOutput(log_file);
    const log = log_file.writer();

    try logLinef(log, "DEBUG", "daemon bootstrap pid={d} path_hash={s} cross_mount={}", .{
        child_pid,
        path_hash,
        cross_mount,
    });
    platform.setBackgroundPriority() catch {
        try logLine(log, "WARN", "failed to set background priority");
    };

    try writePidFile(allocator, pid_path, @intCast(child_pid));
    try logLinef(log, "INFO", "wrote pid file {s}", .{pid_path});

    var state = types.ScanProgressState.init(start_time);
    state.state.store(@intFromEnum(types.SessionState.scanning), .release);
    state.start_time = start_time;

    var context = ipc.ServerContext{
        .allocator = allocator,
        .state = &state,
        .config = config,
        .path = path,
        .path_hash = path_hash,
        .start_time = start_time,
        .socket_path = sock_path,
    };
    try logLinef(log, "DEBUG", "starting ipc socket at {s}", .{sock_path});

    const server = try std.Thread.spawn(.{}, ipc.startServer, .{&context});
    defer {
        state.complete.store(true, .release);
        state.state.store(@intFromEnum(types.SessionState.cleaned), .release);
        server.join();
        cleanupStale(allocator, path_hash, config) catch {};
        logLine(log, "INFO", "background process finished") catch {};
    }

    try logLine(log, "INFO", "background process started");

    const summary = scanner.scanWithProgress(allocator, path, cross_mount, .{
        .progress = &state,
        .cross_mount = cross_mount,
        .verbose = verbose,
    }) catch |err| {
        if (err == error.Canceled) {
            state.state.store(@intFromEnum(types.SessionState.err), .release);
            try logLine(log, "WARN", "scan canceled");
        } else {
            state.state.store(@intFromEnum(types.SessionState.err), .release);
            try logLinef(log, "ERROR", "scan failed: {s}", .{@errorName(err)});
        }
        state.complete.store(true, .release);
        return;
    };

    state.state.store(@intFromEnum(types.SessionState.completing), .release);
    try logLinef(
        log,
        "DEBUG",
        "scan finished duration_ms={d} entries={d} warnings={s}",
        .{
            summary.result.duration_ms,
            summary.result.entry_count,
            if (summary.had_warnings) "true" else "false",
        },
    );

    cache.writeCache(allocator, path_hash, &summary.result, config) catch |err| {
        state.state.store(@intFromEnum(types.SessionState.err), .release);
        state.complete.store(true, .release);
        try logLinef(log, "ERROR", "cache write failed: {s}", .{@errorName(err)});
        return;
    };

    const records = platform.getSubtreeGencounts(allocator, path, 0) catch null;
    if (records) |cached_records| {
        defer {
            for (cached_records) |record| {
                allocator.free(record.path);
            }
            allocator.free(cached_records);
        }
        cache.writeGencounts(allocator, path_hash, cached_records, config) catch {
            try logLine(log, "WARN", "gencount write failed");
        };
    } else {
        try logLine(log, "DEBUG", "no gencount records captured");
    }

    state.state.store(@intFromEnum(types.SessionState.done), .release);
    state.percent_complete_x10.store(1000, .release);
    state.estimated_remaining_seconds.store(0, .release);
    state.complete.store(true, .release);
    try logLine(log, "INFO", "scan complete");
}

fn writePidFile(allocator: Allocator, pid_path: []const u8, pid: u32) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{pid_path});
    defer allocator.free(tmp_path);

    var file = try std.fs.cwd().createFile(tmp_path, .{
        .truncate = true,
        .read = false,
        .mode = 0o600,
    });
    defer file.close();
    try file.writer().print("{d}\n", .{pid});
    try std.fs.cwd().rename(tmp_path, pid_path);
}

fn readPidFile(allocator: Allocator, pid_path: []const u8) !u32 {
    const raw = try std.fs.cwd().readFileAlloc(allocator, pid_path, 128);
    defer allocator.free(raw);

    const text = std.mem.trim(u8, raw, "\n\r");
    return std.fmt.parseUnsigned(u32, text, 10) catch return error.InvalidData;
}

fn isPidAlive(pid: u32) bool {
    if (pid == 0) return false;
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

fn redirectOutput(file: std.fs.File) !void {
    try std.posix.fchmod(file.handle, 0o600);
    try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
    try std.posix.dup2(file.handle, std.posix.STDERR_FILENO);
}

fn logLine(writer: anytype, level: []const u8, message: []const u8) !void {
    const stamp = try output.formatTimestampISO(std.heap.page_allocator, std.time.timestamp());
    defer std.heap.page_allocator.free(stamp);
    try writer.print("{s} [{s}] {s}\n", .{ stamp, level, message });
}

fn logLinef(writer: anytype, level: []const u8, comptime format: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(std.heap.page_allocator, format, args);
    defer std.heap.page_allocator.free(message);
    try logLine(writer, level, message);
}
