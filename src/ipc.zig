const std = @import("std");
const builtin = @import("builtin");
const types = @import("./types.zig");
const cache = @import("./cache.zig");
const output = @import("./output.zig");

const Allocator = std.mem.Allocator;

const StatusPayload = struct {
    path: []const u8,
    pid: u32,
    status: []const u8,
    start_time: []const u8,
    elapsed_seconds: u64,
    files_scanned: u64,
    bytes_scanned: u64,
    estimated_remaining_seconds: ?u32,
    percent_complete: ?f32,
};

const CancelPayload = struct {
    pid: u32,
    path: []const u8,
    status: []const u8,
};

pub const ServerContext = struct {
    allocator: Allocator,
    state: *types.ScanProgressState,
    config: types.Config,
    path: []const u8,
    path_hash: []const u8,
    start_time: i64,
    socket_path: []const u8,
};

const UnknownCommandPayload = struct {
    @"error": []const u8,
    command: []const u8,
};

const ResultUnavailablePayload = struct {
    @"error": []const u8,
    partial_result: ?[]const u8,
};

pub fn startServer(context: *ServerContext) !void {
    std.fs.cwd().deleteFile(context.socket_path) catch {};

    const address = try std.net.Address.initUnix(context.socket_path);

    const listener = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listener);

    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    std.posix.fchmod(listener, 0o600) catch {};
    try std.posix.listen(listener, 16);

    while (true) {
        const is_complete = context.state.complete.load(.acquire);
        const timeout: i32 = if (is_complete) 250 else -1;

        var pfd = [_]std.posix.pollfd{.{ .fd = listener, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&pfd, timeout);
        if (ready == 0) {
            if (context.state.complete.load(.acquire)) break;
            continue;
        }

        const client = try std.posix.accept(listener, null, null, 0);
        defer std.posix.close(client);

        const command = readCommand(context.allocator, client) catch continue;
        defer context.allocator.free(command);
        if (command.len == 0) continue;

        if (std.mem.eql(u8, command, "status")) {
            try sendStatus(context, client);
            continue;
        }

        if (std.mem.eql(u8, command, "cancel")) {
                const complete = context.state.complete.load(.acquire);
                const status = if (complete) "already_complete" else "cancelled";
                if (!complete) {
                    context.state.cancel_requested.store(true, .release);
                    if (context.state.state.load(.acquire) != @intFromEnum(types.SessionState.done)) {
                        context.state.state.store(@intFromEnum(types.SessionState.err), .release);
                    }
                }
        try sendJson(client, CancelPayload{
                .status = status,
                .pid = currentPid(),
                .path = context.path,
            });
            continue;
        }

        if (std.mem.eql(u8, command, "result")) {
            const response = try buildResultResponse(context);
            defer context.allocator.free(response);
            try sendRaw(client, response);
            continue;
        }

        try sendJson(client, UnknownCommandPayload{
            .@"error" = "unknown command",
            .command = command,
        });
    }
}

pub fn sendCommand(allocator: Allocator, socket_path: []const u8, command: []const u8) ![]u8 {
    const fd = try connectSocket(allocator, socket_path);
    defer std.posix.close(fd);

    _ = try writeAll(fd, command);
    _ = try writeAll(fd, "\n");

    var response = std.array_list.Managed(u8).init(allocator);
    defer response.deinit();

    var buffer: [512]u8 = undefined;
    while (true) {
        const read_count = std.posix.read(fd, &buffer) catch return error.ReadFailed;
        if (read_count == 0) break;

        var idx: usize = 0;
        while (idx < @as(usize, @intCast(read_count))) {
            const byte = buffer[idx];
            if (byte == '\n') return response.toOwnedSlice();
            try response.append(byte);
            idx += 1;
        }
    }

    return response.toOwnedSlice();
}

pub fn queryAllSessions(allocator: Allocator, config: types.Config) ![]types.SessionInfo {
    var dir = std.fs.cwd().openDir(config.cache_dir, .{ .iterate = true }) catch {
        return try allocator.alloc(types.SessionInfo, 0);
    };
    defer dir.close();

    var it = dir.iterate();
    var sessions = std.array_list.Managed(types.SessionInfo).init(allocator);

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pid")) continue;

        const base = std.fs.path.stem(entry.name);
        const pid_file = try std.fs.path.join(allocator, &.{ config.cache_dir, entry.name });
        defer allocator.free(pid_file);

        const pid = parsePidFromFile(allocator, pid_file) catch {
            std.fs.cwd().deleteFile(pid_file) catch {};
            continue;
        };
        if (!isPidAlive(pid)) {
            try cleanupByPid(allocator, config, pid);
            continue;
        }

        const socket_path = try cache.sockFilePath(allocator, config.cache_dir, base);
        defer allocator.free(socket_path);

        const raw = sendCommand(allocator, socket_path, "status") catch {
            try cleanupByPid(allocator, config, pid);
            continue;
        };
        defer allocator.free(raw);

        const parsed = std.json.parseFromSlice(
            StatusPayload,
            allocator,
            raw,
            .{},
        ) catch {
            continue;
        };
        defer parsed.deinit();

        const now = std.time.timestamp();
        const elapsed = @as(i64, @intCast(parsed.value.elapsed_seconds));
        const start_time = if (now >= elapsed) now - elapsed else now;

        const session = types.SessionInfo{
            .path = try allocator.dupe(u8, parsed.value.path),
            .pid = parsed.value.pid,
            .status = try allocator.dupe(u8, parsed.value.status),
            .start_time = start_time,
            .elapsed_seconds = parsed.value.elapsed_seconds,
            .files_scanned = parsed.value.files_scanned,
            .bytes_scanned = parsed.value.bytes_scanned,
            .estimated_remaining_seconds = parsed.value.estimated_remaining_seconds,
            .percent_complete = parsed.value.percent_complete,
        };
        try sessions.append(session);
    }

    return sessions.toOwnedSlice();
}

pub fn resolveSocketPathByPid(allocator: Allocator, config: types.Config, target_pid: u32) !?[]u8 {
    var dir = std.fs.cwd().openDir(config.cache_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pid")) continue;

        const pid_file = try std.fs.path.join(allocator, &.{ config.cache_dir, entry.name });
        defer allocator.free(pid_file);

        const pid = parsePidFromFile(allocator, pid_file) catch continue;
        if (pid != target_pid) continue;

        const stem = std.fs.path.stem(entry.name);
        const socket = try cache.sockFilePath(allocator, config.cache_dir, stem);
        return try allocator.dupe(u8, socket);
    }

    return null;
}

fn sendStatus(context: *ServerContext, fd: std.posix.fd_t) !void {
    const now = std.time.timestamp();
    const elapsed = if (now > context.start_time) now - context.start_time else 0;
    const snapshot = context.state.snapshot(now);
    const session_state = @as(types.SessionState, @enumFromInt(context.state.state.load(.acquire)));
    const status_text = types.sessionStatusText(session_state);

    const start_time = try output.formatTimestampISO(context.allocator, context.start_time);
    defer context.allocator.free(start_time);

    try sendJson(fd, StatusPayload{
        .path = context.path,
        .pid = currentPid(),
        .status = status_text,
        .start_time = start_time,
        .elapsed_seconds = @intCast(elapsed),
        .files_scanned = snapshot.files_scanned,
        .bytes_scanned = snapshot.bytes_scanned,
        .estimated_remaining_seconds = snapshot.estimated_remaining_seconds,
        .percent_complete = snapshot.percent_complete,
    });
}

fn buildResultResponse(context: *ServerContext) ![]u8 {
    while (!context.state.complete.load(.acquire)) {
        std.Thread.sleep(50_000_000);
    }

    if (context.state.state.load(.acquire) == @intFromEnum(types.SessionState.err)) {
        const payload = ResultUnavailablePayload{
            .@"error" = "scan failed",
            .partial_result = null,
        };
        var out = std.array_list.Managed(u8).init(context.allocator);
        defer out.deinit();
        var out_writer = out.writer();
        var out_adapter = out_writer.adaptToNewApi(&.{});
        try std.json.Stringify.value(payload, .{}, &out_adapter.new_interface);
        try out.append('\n');
        return out.toOwnedSlice();
    }

    const result = cache.readCache(
        context.allocator,
        context.path,
        context.path_hash,
        context.config,
    ) catch {
        const payload = ResultUnavailablePayload{
            .@"error" = "cache read failed",
            .partial_result = null,
        };
        var out = std.array_list.Managed(u8).init(context.allocator);
        defer out.deinit();
        var out_writer = out.writer();
        var out_adapter = out_writer.adaptToNewApi(&.{});
        try std.json.Stringify.value(payload, .{}, &out_adapter.new_interface);
        try out.append('\n');
        return out.toOwnedSlice();
    };
    if (result == null) {
        const payload = ResultUnavailablePayload{
            .@"error" = "cache read failed",
            .partial_result = null,
        };
        var out = std.array_list.Managed(u8).init(context.allocator);
        defer out.deinit();
        var out_writer = out.writer();
        var out_adapter = out_writer.adaptToNewApi(&.{});
        try std.json.Stringify.value(payload, .{}, &out_adapter.new_interface);
        try out.append('\n');
        return out.toOwnedSlice();
    }
    const scan_result = result.?;

    var out = std.array_list.Managed(u8).init(context.allocator);
    defer out.deinit();
    var out_writer = out.writer();
    var out_adapter = out_writer.adaptToNewApi(&.{});

    const start_time = if (scan_result.cache_timestamp) |ts| ts else scan_result.timestamp;
    const refresh = output.RefreshInfo{
        .status = "complete",
        .pid = null,
        .estimated_remaining_seconds = null,
    };
    try output.formatJson(context.allocator, &out_adapter.new_interface, &scan_result, 255, 65535, start_time, refresh);
    return out.toOwnedSlice();
}

fn sendJson(fd: std.posix.fd_t, payload: anytype) !void {
    var out = try std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 128);
    defer out.deinit();

    var out_writer = out.writer();
    var out_adapter = out_writer.adaptToNewApi(&.{});
    try std.json.Stringify.value(payload, .{}, &out_adapter.new_interface);
    try out.append('\n');
    _ = try writeAll(fd, out.items);
}

fn sendRaw(fd: std.posix.fd_t, data: []const u8) !void {
    const fd_arg = fd;
    if (std.mem.endsWith(u8, data, "\n")) {
        _ = try writeAll(fd_arg, data);
    } else {
        const with_newline = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\n", .{data});
        defer std.heap.page_allocator.free(with_newline);
        _ = try writeAll(fd_arg, with_newline);
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !usize {
    var offset: usize = 0;
    while (offset < data.len) {
        const written = try std.posix.write(fd, data[offset..]);
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
    return data.len;
}

fn readCommand(allocator: Allocator, fd: std.posix.fd_t) ![]u8 {
    var response = std.array_list.Managed(u8).init(allocator);
    var buf: [1]u8 = undefined;

    while (true) {
        const n = try std.posix.read(fd, buf[0..]);
        if (n == 0) break;
        if (buf[0] == '\n') break;
        try response.append(buf[0]);
    }

    return response.toOwnedSlice();
}

fn connectSocket(allocator: Allocator, socket_path: []const u8) !std.posix.fd_t {
    _ = allocator;
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);

    const address = try std.net.Address.initUnix(socket_path);

    try std.posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn isPidAlive(pid: u32) bool {
    if (pid == 0) return false;
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

fn parsePidFromFile(allocator: Allocator, pid_path: []const u8) !u32 {
    const raw = try std.fs.cwd().readFileAlloc(allocator, pid_path, 64);
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, "\n\r ");
    return std.fmt.parseUnsigned(u32, text, 10) catch error.InvalidData;
}

fn cleanupByPid(allocator: Allocator, config: types.Config, pid: u32) !void {
    var dir = std.fs.cwd().openDir(config.cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pid")) continue;

        const pid_file = try std.fs.path.join(allocator, &.{ config.cache_dir, entry.name });
        defer allocator.free(pid_file);

        const parsed = parsePidFromFile(allocator, pid_file) catch continue;
        if (parsed != pid) continue;

        std.fs.cwd().deleteFile(pid_file) catch {};
        const stem = std.fs.path.stem(entry.name);
        const sock_path = try cache.sockFilePath(allocator, config.cache_dir, stem);
        defer allocator.free(sock_path);
        std.fs.cwd().deleteFile(sock_path) catch {};
        return;
    }
}
