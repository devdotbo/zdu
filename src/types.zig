const std = @import("std");

const Allocator = std.mem.Allocator;

pub const FsType = enum(u8) {
    apfs = 1,
    hfsplus = 2,
    ext4 = 3,
    xfs = 4,
    btrfs = 5,
    other = 255,
};

pub const SessionState = enum(u8) {
    idle = 0,
    scanning = 1,
    completing = 2,
    done = 3,
    err = 4,
    cleaned = 5,
};

pub fn sessionStatusText(state: SessionState) []const u8 {
    return switch (state) {
        .idle => "idle",
        .scanning => "running",
        .completing => "completing",
        .done => "complete",
        .err => "error",
        .cleaned => "idle",
    };
}

pub fn sessionStateFromText(text: []const u8) ?SessionState {
    if (std.mem.eql(u8, text, "idle")) return .idle;
    if (std.mem.eql(u8, text, "running")) return .scanning;
    if (std.mem.eql(u8, text, "completing")) return .completing;
    if (std.mem.eql(u8, text, "complete")) return .done;
    if (std.mem.eql(u8, text, "error")) return .err;
    if (std.mem.eql(u8, text, "cleaned")) return .cleaned;
    return null;
}

pub const VolumeInfo = struct {
    mount_point: []const u8,
    fs_type: FsType,
    fs_identifier: []const u8,
    total_bytes: u64,
    used_bytes: u64,
    free_bytes: u64,

    pub fn filesystemName(self: VolumeInfo) []const u8 {
        return switch (self.fs_type) {
            .apfs => "apfs",
            .hfsplus => "hfs+",
            .ext4 => "ext4",
            .xfs => "xfs",
            .btrfs => "btrfs",
            .other => if (self.fs_identifier.len > 0) self.fs_identifier else self.mount_point,
        };
    }
};

pub const GencountRecord = struct {
    path: []const u8,
    value: u64,
};

pub const DirectoryEntry = struct {
    path: []const u8,
    size_bytes: u64,
    file_count: u32,
    dir_count: u32,
    depth: u8,
    children: []DirectoryEntry,

    pub fn percentOf(self: DirectoryEntry, total: u64) f64 {
        if (total == 0) return 0.0;
        return (100.0 * @as(f64, @floatFromInt(self.size_bytes))) / @as(f64, @floatFromInt(total));
    }
};

pub const ScanProgress = struct {
    files_scanned: u64,
    dirs_scanned: u64,
    bytes_scanned: u64,
    errors_count: u32,
    estimated_remaining_seconds: ?u32,
    percent_complete: ?f32,
};

pub const ScanProgressState = struct {
    files_scanned: std.atomic.Value(u64) = .init(0),
    dirs_scanned: std.atomic.Value(u64) = .init(0),
    bytes_scanned: std.atomic.Value(u64) = .init(0),
    errors_count: std.atomic.Value(u32) = .init(0),
    estimated_remaining_seconds: std.atomic.Value(i32) = .init(-1),
    percent_complete_x10: std.atomic.Value(i32) = .init(-1),
    state: std.atomic.Value(u8) = .init(@intFromEnum(SessionState.idle)),
    complete: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    start_time: i64 = 0,

    pub fn init(start_time: i64) ScanProgressState {
        return .{ .start_time = start_time };
    }

    pub fn snapshot(self: *const ScanProgressState, now: i64) ScanProgress {
        const percent_x10 = self.percent_complete_x10.load(.acquire);
        const remaining = self.estimated_remaining_seconds.load(.acquire);
        const percent: ?f32 = if (percent_x10 < 0) null else @as(f32, @floatFromInt(percent_x10)) / 10.0;
        return .{
            .files_scanned = self.files_scanned.load(.acquire),
            .dirs_scanned = self.dirs_scanned.load(.acquire),
            .bytes_scanned = self.bytes_scanned.load(.acquire),
            .errors_count = self.errors_count.load(.acquire),
            .estimated_remaining_seconds = if (remaining < 0) null else @as(u32, @intCast(remaining)),
            .percent_complete = percent,
        };
    }
};

pub const SessionInfo = struct {
    path: []const u8,
    pid: ?u32,
    status: []const u8,
    start_time: i64,
    elapsed_seconds: u64,
    files_scanned: u64,
    bytes_scanned: u64,
    estimated_remaining_seconds: ?u32,
    percent_complete: ?f32,
};

pub const ScanResult = struct {
    path: []const u8,
    timestamp: i64,
    duration_ms: u64,
    volume_info: VolumeInfo,
    root_entry: *DirectoryEntry,
    entry_count: u64,
    cache_timestamp: ?i64 = null,
};

pub const CacheHeader = extern struct {
    magic: [4]u8,
    version: u32,
    timestamp: i64,
    scan_duration_ms: u64,
    entry_count: u64,
};

comptime {
    std.debug.assert(@sizeOf(CacheHeader) == 32);
}

pub const Config = struct {
    base_dir: []const u8,
    cache_dir: []const u8,
    log_dir: []const u8,
    max_cache_bytes: u64,
    default_depth: u8,
    default_top: u16,
    max_log_age_days: u16,

    pub fn defaults() Config {
        return .{
            .base_dir = "~/.zigdu",
            .cache_dir = "~/.zigdu/cache",
            .log_dir = "~/.zigdu/logs",
            .max_cache_bytes = 1024 * 1024 * 1024,
            .default_depth = 3,
            .default_top = 20,
            .max_log_age_days = 30,
        };
    }

    pub fn validate(config: Config) Config {
        var out = config;

        if (out.max_cache_bytes < 10 * 1024 * 1024) {
            std.debug.print("warning: max_cache_bytes {d} below minimum, clamped to {d}\n", .{ out.max_cache_bytes, 10 * 1024 * 1024 });
            out.max_cache_bytes = 10 * 1024 * 1024;
        }

        if (out.default_depth == 0) {
            std.debug.print("warning: default_depth {d} is invalid, clamped to {d}\n", .{ out.default_depth, 1 });
            out.default_depth = 1;
        }
        if (out.default_depth > 255) {
            std.debug.print("warning: default_depth {d} above 255, clamped to 255\n", .{out.default_depth});
            out.default_depth = 255;
        }

        if (out.default_top == 0) {
            std.debug.print("warning: default_top {d} is invalid, clamped to {d}\n", .{ out.default_top, 1 });
            out.default_top = 1;
        }
        if (out.default_top > 65535) {
            std.debug.print("warning: default_top {d} above 65535, clamped to 65535\n", .{out.default_top});
            out.default_top = 65535;
        }

        if (out.max_log_age_days == 0) {
            std.debug.print("warning: max_log_age_days {d} is invalid, clamped to {d}\n", .{ out.max_log_age_days, 1 });
            out.max_log_age_days = 1;
        }

        return out;
    }

    fn trimSpace(text: []const u8) []const u8 {
        var start: usize = 0;
        while (start < text.len and std.ascii.isWhitespace(text[start])) start += 1;
        var end: usize = text.len;
        while (end > start and std.ascii.isWhitespace(text[end - 1])) end -= 1;
        return text[start..end];
    }

    pub fn load(allocator: Allocator) !Config {
        var out = defaults();
        var saw_cache_dir = false;
        var saw_log_dir = false;
        const config_path = expandHome(allocator, "~/.zigdu/config") catch return out;
        defer allocator.free(config_path);

        const file = std.fs.cwd().openFile(config_path, .{}) catch {
            return validate(out);
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(allocator, 8 * 1024);
        defer allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line_raw| {
            const line = trimSpace(line_raw);
            if (line.len == 0 or line[0] == '#') continue;

            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = trimSpace(line[0..equals]);
            const value = trimSpace(line[equals + 1 ..]);
            if (value.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(key, "cache_dir")) {
                saw_cache_dir = true;
                out.cache_dir = try allocator.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(key, "log_dir")) {
                saw_log_dir = true;
                out.log_dir = try allocator.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(key, "base_dir")) {
                out.base_dir = try allocator.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(key, "max_cache_bytes")) {
                out.max_cache_bytes = std.fmt.parseInt(u64, value, 10) catch blk: {
                    std.debug.print("warning: invalid max_cache_bytes value: {s}\n", .{value});
                    break :blk out.max_cache_bytes;
                };
            } else if (std.ascii.eqlIgnoreCase(key, "default_depth")) {
                const raw_depth = std.fmt.parseInt(u16, value, 10) catch blk: {
                    std.debug.print("warning: invalid default_depth value: {s}\n", .{value});
                    break :blk out.default_depth;
                };
                out.default_depth = @as(u8, @min(255, raw_depth));
            } else if (std.ascii.eqlIgnoreCase(key, "default_top")) {
                out.default_top = std.fmt.parseInt(u16, value, 10) catch blk: {
                    std.debug.print("warning: invalid default_top value: {s}\n", .{value});
                    break :blk out.default_top;
                };
            } else if (std.ascii.eqlIgnoreCase(key, "max_log_age_days")) {
                out.max_log_age_days = std.fmt.parseInt(u16, value, 10) catch blk: {
                    std.debug.print("warning: invalid max_log_age_days value: {s}\n", .{value});
                    break :blk out.max_log_age_days;
                };
            }
        }

        if (!saw_cache_dir) {
            const cache_tail = try std.fs.path.join(allocator, &.{ out.base_dir, "cache" });
            out.cache_dir = cache_tail;
        }
        if (!saw_log_dir) {
            const log_tail = try std.fs.path.join(allocator, &.{ out.base_dir, "logs" });
            out.log_dir = log_tail;
        }

        return validate(out);
    }

    pub fn cleanupOldLogs(config: Config) !void {
        var dir = std.fs.cwd().openDir(config.log_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        const now = std.time.timestamp();
        const max_age_seconds = @as(i64, config.max_log_age_days) * 86_400;

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

            const stat = dir.statFile(entry.name) catch continue;
            const age = now - @as(i64, @intCast(stat.mtime));
            if (age > max_age_seconds) {
                const path = try std.fs.path.join(std.heap.page_allocator, &.{ config.log_dir, entry.name });
                defer std.heap.page_allocator.free(path);
                std.fs.cwd().deleteFile(path) catch {};
            }
        }
    }
};

fn expandHome(allocator: Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return try allocator.dupe(u8, input);
    if (input[0] != '~') return try allocator.dupe(u8, input);
    if (input.len > 1 and input[1] != std.fs.path.sep) return try allocator.dupe(u8, input);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return try allocator.dupe(u8, input);
    const home_trimmed = if (home.len > 0 and home[home.len - 1] == std.fs.path.sep)
        home[0 .. home.len - 1]
    else
        home;

    if (input.len == 1) return home_trimmed;

    return try std.fs.path.join(allocator, &.{ home_trimmed, input[1..] });
}
