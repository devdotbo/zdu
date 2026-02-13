const std = @import("std");
const types = @import("./types.zig");
const pathmod = @import("./path.zig");
const scanner = @import("./scanner.zig");
const output = @import("./output.zig");
const cache = @import("./cache.zig");
const daemon = @import("./daemon.zig");
const ipc = @import("./ipc.zig");
const platform = @import("./platform/generic.zig");

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

    if ((@intFromBool(options.sessions) + @intFromBool(options.status) + @intFromBool(options.kill_pid != null)) > 1) {
        try stderr.print("error: --sessions, --status, and --kill are mutually exclusive\n", .{});
        return error.InvalidArgument;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try types.Config.load(allocator);
    config.base_dir = try pathmod.expandHome(allocator, config.base_dir);
    config.cache_dir = try pathmod.expandHome(allocator, config.cache_dir);
    config.log_dir = try pathmod.expandHome(allocator, config.log_dir);

    try ensureDir(config.base_dir);
    try ensureDir(config.cache_dir);
    try ensureDir(config.log_dir);
    try config.cleanupOldLogs();

    if ((@intFromBool(options.sessions) + @intFromBool(options.status) + @intFromBool(options.kill_pid != null)) == 1) {
        return try runSessionCommands(&options, allocator, config);
    }

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
    var served_from_cache = false;
    var had_warnings = false;
    var refresh: ?output.RefreshInfo = .{
        .status = "none",
        .pid = null,
        .estimated_remaining_seconds = null,
    };

    if (use_cache) {
        if (cache.readCache(allocator, canonical_path, hash, config)) |cached| {
            result = cached;
            used_cache = true;
            served_from_cache = true;

            if (options.verbose) {
                const age = if (result.cache_timestamp) |ts| blk: {
                    const now_ts = now();
                    if (ts <= 0 or ts > @as(i64, @intCast(now_ts))) break :blk 0;
                    break :blk now_ts - @as(u64, @intCast(ts));
                } else 0;
                try stderr.print("[DEBUG] cache hit: path_hash={s}, age={d}s\n", .{ hash, age });
            }

            if (try performApfsWarmRefresh(
                allocator,
                canonical_path,
                hash,
                &result,
                config,
                options.cross_mount,
                options.verbose,
            ) catch null) |summary| {
                result = summary.result;
                result.cache_timestamp = null;
                had_warnings = summary.had_warnings;
                served_from_cache = false;
            }

            if (daemon.isDuplicate(allocator, hash, config) catch null) |pid| {
                const status = statusFromPid(allocator, config, pid) catch null;
                const normalized_status = if (status) |payload| normalizeRefreshStatus(payload.status) else "running";
                refresh = .{
                    .status = normalized_status,
                    .pid = pid,
                    .estimated_remaining_seconds = if (status) |payload| payload.estimated_remaining_seconds else null,
                };
                if (options.verbose) {
                    try stderr.print("background refresh already running (pid {d})\n", .{pid});
                }
            } else if (!options.wait and !options.force) {
                const spawned_pid = spawnBackgroundIfIdle(
                    allocator,
                    canonical_path,
                    hash,
                    config,
                    depth,
                    top,
                    options.cross_mount,
                    options.verbose,
                    options.force,
                ) catch null;
                if (spawned_pid) |pid| {
                    refresh = .{ .status = "running", .pid = pid, .estimated_remaining_seconds = null };
                    if (options.verbose) {
                        try stderr.print("background refresh started pid {d}\n", .{pid});
                    }
                } else if (options.verbose) {
                    try stderr.print("background refresh not started\n", .{});
                }
            }
        } else |_| {
            if (options.verbose) {
                try stderr.print("[DEBUG] cache miss for {s}\n", .{canonical_path});
            }
        }
    }

    if (!used_cache) {
        const scan = try scanner.scanWithProgress(
            allocator,
            canonical_path,
            options.cross_mount,
            .{ .verbose = options.verbose },
        );
        result = scan.result;
        had_warnings = scan.had_warnings;
        result.cache_timestamp = null;

        if (options.verbose) try stderr.print("[DEBUG] scan complete in {} ms\n", .{result.duration_ms});
        cache.writeCache(allocator, hash, &result, config) catch |err| {
            if (options.verbose) {
                try stderr.print("warning: cache write failed ({s})\n", .{@errorName(err)});
            }
        };
        if (options.verbose) try stderr.print("[DEBUG] scan complete (entries={d})\n", .{result.entry_count});
    }

    if (used_cache) {
        result.cache_timestamp = result.cache_timestamp orelse result.timestamp;
        if (served_from_cache) had_warnings = false;
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
            refresh,
        );
    } else {
        try output.formatHumanReadable(
            allocator,
            stdout,
            &result,
            depth,
            top,
            result.cache_timestamp,
            refresh,
        );
    }

    return if (had_warnings) 2 else 0;
}

fn runSessionCommands(options: *const CliOptions, allocator: Allocator, config: types.Config) !u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (options.sessions) {
        const sessions = try ipc.queryAllSessions(allocator, config);
        if (sessions.len == 0) {
            if (options.json) {
                try output.formatSessionsJson(allocator, stdout, &[_]output.StatusJson{});
            } else {
                try stdout.print("no active sessions\n", .{});
            }
            return 0;
        }

        var payloads = try allocator.alloc(output.StatusJson, sessions.len);
        defer allocator.free(payloads);
        for (sessions, 0..) |session, idx| {
            payloads[idx] = try toStatusJsonFromSession(allocator, session);
        }
        defer {
            for (payloads) |entry| {
                allocator.free(entry.path);
                allocator.free(entry.status);
                allocator.free(entry.start_time);
            }
            for (sessions) |session| {
                allocator.free(session.path);
                allocator.free(session.status);
            }
            allocator.free(sessions);
        }

        if (options.json) {
            try output.formatSessionsJson(allocator, stdout, payloads);
        } else {
            for (payloads) |entry| {
                try stdout.print(
                    "{s}\tpid={d}\tstatus={s}\tfiles={d}\tbytes={d}\tremaining={?d}\n",
                    .{
                        entry.path,
                        entry.pid,
                        entry.status,
                        entry.files_scanned,
                        entry.bytes_scanned,
                        entry.estimated_remaining_seconds,
                    },
                );
            }
        }
        return 0;
    }

    if (options.status) {
        const expanded_input = try pathmod.expandHome(allocator, options.path);
        defer allocator.free(expanded_input);
        const canonical_path = try pathmod.canonicalize(allocator, expanded_input);
        defer allocator.free(canonical_path);
        const hash = try pathmod.hashPath(allocator, canonical_path);
        defer allocator.free(hash);

        const status = statusForPath(allocator, config, hash) catch {
            if (options.json) {
                try output.formatErrorJson(allocator, stdout, "no active session for path", 1);
            } else {
                try stderr.print("status: no active session for path {s}\n", .{canonical_path});
            }
            return 1;
        };

        if (options.json) {
            try output.formatStatusJson(allocator, stdout, status);
        } else {
            try stdout.print(
                "path: {s}\npid: {d}\nstatus: {s}\nelapsed_seconds: {d}\nfiles_scanned: {d}\nbytes_scanned: {d}\nstart_time: {s}\n",
                .{
                    status.path,
                    status.pid,
                    status.status,
                    status.elapsed_seconds,
                    status.files_scanned,
                    status.bytes_scanned,
                    status.start_time,
                },
            );
        }
        allocator.free(status.path);
        allocator.free(status.status);
        allocator.free(status.start_time);
        return 0;
    }

    if (options.kill_pid) |target_pid| {
        const socket_path = ipc.resolveSocketPathByPid(allocator, config, target_pid) catch null;
        if (socket_path == null) {
            if (options.json) {
                try output.formatErrorJson(allocator, stdout, "no active session for pid", 1);
            } else {
                try stderr.print("kill: no active session for pid {d}\n", .{target_pid});
            }
            return 1;
        }
        defer allocator.free(socket_path.?);

        const response = ipc.sendCommand(allocator, socket_path.?, "cancel") catch {
            if (options.json) {
                try output.formatErrorJson(allocator, stdout, "failed to signal session", 1);
            } else {
                try stderr.print("kill: failed to signal pid {d}\n", .{target_pid});
            }
            return 1;
        };
        defer allocator.free(response);

        const parsed = parseCancelPayload(allocator, response) catch {
            if (options.json) {
                try output.formatErrorJson(allocator, stdout, "invalid cancel response", 1);
            } else {
                try stderr.print("kill: invalid response from session {d}\n", .{target_pid});
            }
            return 1;
        };
        defer allocator.free(parsed.path);
        defer allocator.free(parsed.status);

        if (options.json) {
            try output.formatCancelJson(allocator, stdout, parsed);
        } else {
            try stdout.print("pid={d} status={s}\n", .{ parsed.pid orelse target_pid, parsed.status });
        }
        return 0;
    }

    return 0;
}

fn statusForPath(allocator: Allocator, config: types.Config, path_hash: []const u8) !output.StatusJson {
    const pid = daemon.isDuplicate(allocator, path_hash, config) catch return error.InvalidArgument;
    if (pid == null) return error.InvalidArgument;
    return statusFromPid(allocator, config, pid.?);
}

fn statusFromPid(allocator: Allocator, config: types.Config, pid: u32) !output.StatusJson {
    const socket_path = ipc.resolveSocketPathByPid(allocator, config, pid) catch return error.InvalidArgument;
    if (socket_path == null) return error.InvalidArgument;
    defer allocator.free(socket_path.?);

    const response = try ipc.sendCommand(allocator, socket_path.?, "status");
    defer allocator.free(response);
    return parseStatusPayload(allocator, response);
}

fn parseStatusPayload(allocator: Allocator, response: []const u8) !output.StatusJson {
    var parsed = try std.json.parseFromSlice(output.StatusJson, allocator, response, .{});
    defer parsed.deinit();
    return .{
        .path = try allocator.dupe(u8, parsed.value.path),
        .pid = parsed.value.pid,
        .status = try allocator.dupe(u8, parsed.value.status),
        .start_time = try allocator.dupe(u8, parsed.value.start_time),
        .elapsed_seconds = parsed.value.elapsed_seconds,
        .files_scanned = parsed.value.files_scanned,
        .bytes_scanned = parsed.value.bytes_scanned,
        .estimated_remaining_seconds = parsed.value.estimated_remaining_seconds,
        .percent_complete = parsed.value.percent_complete,
    };
}

fn parseCancelPayload(allocator: Allocator, response: []const u8) !output.CancelJson {
    const CancelPayloadShim = struct {
        pid: ?u32 = null,
        path: []const u8 = "",
        status: []const u8,
    };
    var parsed = try std.json.parseFromSlice(CancelPayloadShim, allocator, response, .{});
    defer parsed.deinit();
    return .{
        .pid = parsed.value.pid,
        .path = try allocator.dupe(u8, parsed.value.path),
        .status = try allocator.dupe(u8, parsed.value.status),
    };
}

fn toStatusJsonFromSession(allocator: Allocator, session: types.SessionInfo) !output.StatusJson {
    return .{
        .path = try allocator.dupe(u8, session.path),
        .pid = session.pid orelse 0,
        .status = try allocator.dupe(u8, session.status),
        .start_time = try output.formatTimestampISO(allocator, session.start_time),
        .elapsed_seconds = session.elapsed_seconds,
        .files_scanned = session.files_scanned,
        .bytes_scanned = session.bytes_scanned,
        .estimated_remaining_seconds = session.estimated_remaining_seconds,
        .percent_complete = session.percent_complete,
    };
}

fn spawnBackgroundIfIdle(
    allocator: Allocator,
    canonical_path: []const u8,
    path_hash: []const u8,
    config: types.Config,
    _depth: u8,
    _top: u16,
    cross_mount: bool,
    verbose: bool,
    force: bool,
) !?u32 {
    if (daemon.isDuplicate(allocator, path_hash, config) catch null != null) return null;
    return try daemon.spawnBackground(
        canonical_path,
        path_hash,
        config,
        _depth,
        _top,
        cross_mount,
        verbose,
        force,
    );
}

fn performApfsWarmRefresh(
    allocator: Allocator,
    path: []const u8,
    path_hash: []const u8,
    cached: *types.ScanResult,
    config: types.Config,
    cross_mount: bool,
    verbose: bool,
) !?scanner.ScanSummary {
    if (verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("apfs: validating subtree gencounts for {s}\n", .{path});
    }

    const current = platform.getSubtreeGencounts(allocator, path, 1) catch return null;
    if (current == null) return null;
    defer {
        for (current.?) |record| allocator.free(record.path);
        allocator.free(current.?);
    }

    const previous = cache.readGencounts(allocator, path_hash, config) catch null;
    if (previous == null) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("apfs: no cached gencounts for {s}\n", .{path});
        }
        try cache.writeGencounts(allocator, path_hash, current.?, config);
        return null;
    }
    defer {
        for (previous.?) |record| allocator.free(record.path);
        allocator.free(previous.?);
    }

    if (!gencountRecordsDifferent(current.?, previous.?)) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("apfs: cache gencounts unchanged for {s}\n", .{path});
        }
        return null;
    }

    const stale_subtrees = try detectStaleSubtrees(allocator, current.?, previous.?);
    defer {
        for (stale_subtrees) |item| allocator.free(item);
        allocator.free(stale_subtrees);
    }

    if (verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("apfs: stale subtrees for {s}: {d}\n", .{ path, stale_subtrees.len });
    }

    const summary = try scanner.partialScan(allocator, path, stale_subtrees, config, cross_mount, null, verbose);
    cached.* = summary.result;
    try cache.writeCache(allocator, path_hash, &summary.result, config);
    try cache.writeGencounts(allocator, path_hash, current.?, config);
    return summary;
}

fn gencountRecordsDifferent(
    current: []const types.GencountRecord,
    previous: []const types.GencountRecord,
) bool {
    if (current.len != previous.len) return true;
    for (current) |record| {
        var found = false;
        for (previous) |cached| {
            if (std.mem.eql(u8, record.path, cached.path) and record.value == cached.value) {
                found = true;
                break;
            }
        }
        if (!found) return true;
    }
    return false;
}

fn detectStaleSubtrees(
    allocator: Allocator,
    current: []const types.GencountRecord,
    previous: []const types.GencountRecord,
) ![][]const u8 {
    var stale = std.ArrayList([]const u8).init(allocator);
    var success = false;
    defer if (!success) {
        for (stale.items) |entry| allocator.free(entry);
        stale.deinit();
    };

    for (current) |record| {
        const prior = findGencountValue(previous, record.path);
        if (prior == null or prior.? != record.value) {
            if (!isDuplicatePath(stale.items, record.path)) {
                try stale.append(try allocator.dupe(u8, record.path));
            }
        }
    }

    for (previous) |record| {
        if (findGencountValue(current, record.path) != null) continue;
        const parent = std.fs.path.dirname(record.path) orelse "";
        const parent_path = try allocator.dupe(u8, parent);
        if (!isDuplicatePath(stale.items, parent_path)) {
            try stale.append(parent_path);
        } else {
            allocator.free(parent_path);
        }
    }

    if (stale.items.len == 0) {
        success = true;
        defer stale.deinit();
        return try allocator.alloc([]const u8, 0);
    }

    std.mem.sort([]const u8, stale.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            if (left.len != right.len) return left.len < right.len;
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    var stale_output = try std.ArrayList([]const u8).initCapacity(allocator, stale.items.len);
    for (stale.items) |candidate| {
        if (isEmptyPath(candidate)) {
            stale_output.clearRetainingCapacity();
            try stale_output.append(candidate);
            break;
        }

        var skip = false;
        for (stale_output.items) |ancestor| {
            if (ancestor.len == 0) {
                skip = true;
                break;
            }
            if (isSubtreeOf(candidate, ancestor)) {
                skip = true;
                break;
            }
        }
        if (!skip) {
            try stale_output.append(candidate);
        }
    }

    if (stale_output.items.len == 0) {
        for (stale.items) |entry| allocator.free(entry);
        stale.deinit();
        success = true;
        return try allocator.alloc([]const u8, 0);
    }

    for (stale.items) |entry| {
        if (!isDuplicatePath(stale_output.items, entry)) {
            allocator.free(entry);
        }
    }
    stale.deinit();

    const result = try allocator.alloc([]const u8, stale_output.items.len);
    for (stale_output.items, 0..) |entry, idx| {
        result[idx] = entry;
    }
    stale_output.deinit();
    success = true;
    return result;
}

fn findGencountValue(records: []const types.GencountRecord, path: []const u8) ?u64 {
    for (records) |record| {
        if (std.mem.eql(u8, record.path, path)) {
            return record.value;
        }
    }
    return null;
}

fn isEmptyPath(path: []const u8) bool {
    return path.len == 0;
}

fn isSubtreeOf(child: []const u8, parent: []const u8) bool {
    if (parent.len == 0) return true;
    if (child.len < parent.len) return false;
    if (!std.mem.eql(u8, child[0..parent.len], parent)) return false;
    if (child.len == parent.len) return true;
    if (child[parent.len] != '/') return false;
    return true;
}

fn isDuplicatePath(list: [][]const u8, path: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
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

fn normalizeRefreshStatus(raw_status: []const u8) []const u8 {
    if (std.mem.eql(u8, raw_status, "complete")) return "idle";
    if (std.mem.eql(u8, raw_status, "done")) return "idle";
    return raw_status;
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
    const defaults = types.Config.defaults();
    try writer.print(
        \\Usage: zigdu [options] [path]
        \\
        \\Options:
        \\  --wait, -w                    wait for scan
        \\  --force, -f                   force fresh scan
        \\  --json, -j                    JSON output
        \\  --verbose, -v                 emit diagnostics
        \\  --cross-mount                 cross filesystem boundaries
        \\  --depth, -d <N> (default {d})   max output depth
        \\  --top, -t <N> (default {d})     max entries per level
        \\  --sessions                    list active sessions
        \\  --status                      query status for resolved path
        \\  --kill <PID>                  stop background session
        \\  --help                        show usage
        \\  --version                     print version
        \\
    , .{ defaults.default_depth, defaults.default_top });
}
