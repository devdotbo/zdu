const std = @import("std");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;

const OutputEntry = struct {
    path: []const u8,
    bytes: u64,
    percent: f64,
    file_count: u32,
    dir_count: u32,
    depth: u8,
};

const JsonEntry = struct {
    path: []const u8,
    bytes: u64,
    percent: f64,
    file_count: u32,
    dir_count: u32,
    depth: u8,
};

const ScanJson = struct {
    path: []const u8,
    cache_timestamp: []const u8,
    cache_age_seconds: u64,
    scan_duration_ms: u64,
    entry_count: u64,
    refresh: ?RefreshPayload,
    volume: struct {
        total_bytes: u64,
        used_bytes: u64,
        free_bytes: u64,
        filesystem: []const u8,
    },
    entries: []const JsonEntry,
};

const RefreshPayload = struct {
        status: []const u8,
        pid: ?u32,
        estimated_remaining_seconds: ?u32,
};

pub const StatusJson = struct {
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

pub const SessionsJson = struct {
    sessions: []const StatusJson,
};

pub const CancelJson = struct {
    pid: ?u32,
    path: []const u8,
    status: []const u8,
};

pub const ErrorJson = struct {
    @"error": []const u8,
    code: u8,
};

pub const RefreshInfo = struct {
    status: []const u8,
    pid: ?u32,
    estimated_remaining_seconds: ?u32,
};

pub fn formatHumanReadable(
    allocator: Allocator,
    writer: anytype,
    result: *const types.ScanResult,
    depth_limit: u8,
    top_n: u16,
    cache_timestamp: ?i64,
    refresh: ?RefreshInfo,
) !void {
    if (cache_timestamp) |ts| {
        const cache_age = try ageHuman(allocator, ts);
        const cache_iso = try formatTimestampISO(allocator, ts);
        defer allocator.free(cache_iso);
        defer allocator.free(cache_age);
        try writer.print("cache: {s} ({s})\n", .{ cache_iso, cache_age });
    } else {
        const stamp = try formatTimestampISO(allocator, result.timestamp);
        defer allocator.free(stamp);
        try writer.print("scan: {s}\n", .{stamp});
    }

    try writer.print("path: {s}\n", .{result.path});
    try writer.print("max depth: {d}  top: {d}\n\n", .{ depth_limit, top_n });

    const total_h = try formatBytes(allocator, result.volume_info.total_bytes);
    defer allocator.free(total_h);
    const used_h = try formatBytes(allocator, result.volume_info.used_bytes);
    defer allocator.free(used_h);
    const free_h = try formatBytes(allocator, result.volume_info.free_bytes);
    defer allocator.free(free_h);

    try writer.print(
        "volume total  {s}\nvolume used   {s}\nvolume free   {s}\n\n",
        .{
            total_h,
            used_h,
            free_h,
        },
    );

    try writer.print("bytes       pct   bar                 path\n", .{});
    try writer.print("---------------------------------------------\n", .{});

    const entries = try filterEntries(allocator, result.root_entry.children, depth_limit, top_n, result.root_entry.size_bytes);
    defer allocator.free(entries);

    if (entries.len == 0) {
        try writer.print("no entries within depth {d}\n", .{depth_limit});
        return;
    }

    for (entries) |entry| {
        const bar = makeBar(entry.percent);
        const absolute_path = if (entry.path.len == 0)
            try allocator.dupe(u8, result.path)
        else
            try std.fs.path.join(allocator, &.{ result.path, entry.path });
        defer allocator.free(absolute_path);

        const human = try formatBytes(allocator, entry.bytes);
        defer allocator.free(human);

        try writer.print("{s:>9}  {d:>5.1}%  {s}  {s}\n", .{
            human,
            entry.percent,
            bar,
            absolute_path,
        });
    }

    if (refresh) |session| {
        const status = session.status;
        const pid_label = if (session.pid) |pid| blk: {
            const t = try std.fmt.allocPrint(allocator, "{}", .{pid});
            break :blk t;
        } else null;
        defer if (pid_label) |text| allocator.free(text);

        if (session.estimated_remaining_seconds) |estimate| {
            const remaining = try std.fmt.allocPrint(allocator, "{d}s", .{estimate});
            defer allocator.free(remaining);
            try writer.print(
                "\nrefresh: status={s} pid={s} estimated_remaining_seconds={s}\n",
                .{
                    status,
                    pid_label orelse "none",
                    remaining,
                },
            );
        } else {
            try writer.print(
                "\nrefresh: status={s} pid={s} estimated_remaining_seconds=unknown\n",
                .{ status, pid_label orelse "none" },
            );
        }
    }
}

pub fn formatJson(
    allocator: Allocator,
    writer: *std.Io.Writer,
    result: *const types.ScanResult,
    depth_limit: u8,
    top_n: u16,
    cache_timestamp: ?i64,
    refresh: ?RefreshInfo,
) !void {
    const stamp = cache_timestamp orelse result.timestamp;
    const age_seconds = ageSeconds(std.time.timestamp(), stamp);
    const cache_iso = try formatTimestampISO(allocator, stamp);
    defer allocator.free(cache_iso);

    const entries = try filterEntries(allocator, result.root_entry.children, depth_limit, top_n, result.root_entry.size_bytes);
    defer allocator.free(entries);

    var json_entries = try std.array_list.Managed(JsonEntry).initCapacity(allocator, entries.len);
    for (entries) |entry| {
        const absolute_path = if (entry.path.len == 0)
            try allocator.dupe(u8, result.path)
        else
            try std.fs.path.join(allocator, &.{ result.path, entry.path });

        try json_entries.append(.{
            .path = absolute_path,
            .bytes = entry.bytes,
            .percent = roundOneDecimal(entry.percent),
            .file_count = entry.file_count,
            .dir_count = entry.dir_count,
            .depth = entry.depth,
        });
    }

    const refresh_payload: ?RefreshPayload = if (refresh) |session| .{
        .status = session.status,
        .pid = session.pid,
        .estimated_remaining_seconds = session.estimated_remaining_seconds,
    } else null;

    const payload = ScanJson{
        .path = result.path,
        .cache_timestamp = cache_iso,
        .cache_age_seconds = age_seconds,
        .scan_duration_ms = result.duration_ms,
        .entry_count = result.entry_count,
        .refresh = refresh_payload,
        .volume = .{
            .total_bytes = result.volume_info.total_bytes,
            .used_bytes = result.volume_info.used_bytes,
            .free_bytes = result.volume_info.free_bytes,
            .filesystem = result.volume_info.filesystemName(),
        },
        .entries = json_entries.items,
    };

    try std.json.Stringify.value(payload, .{}, writer);
    try writer.writeByte('\n');
}

pub fn formatSessionsJson(
    allocator: Allocator,
    writer: *std.Io.Writer,
    sessions: []const StatusJson,
) !void {
    _ = allocator;
    const payload = SessionsJson{ .sessions = sessions };
    try std.json.Stringify.value(payload, .{}, writer);
    try writer.writeByte('\n');
}

pub fn formatStatusJson(
    allocator: Allocator,
    writer: *std.Io.Writer,
    status: StatusJson,
) !void {
    _ = allocator;
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeByte('\n');
}

pub fn formatCancelJson(
    allocator: Allocator,
    writer: *std.Io.Writer,
    payload: CancelJson,
) !void {
    _ = allocator;
    try std.json.Stringify.value(payload, .{}, writer);
    try writer.writeByte('\n');
}

pub fn formatErrorJson(
    allocator: Allocator,
    writer: *std.Io.Writer,
    message: []const u8,
    exit_code: u8,
) !void {
    _ = allocator;
    try std.json.Stringify.value(ErrorJson{ .@"error" = message, .code = exit_code }, .{}, writer);
    try writer.writeByte('\n');
}

pub fn filterEntries(
    allocator: Allocator,
    source: []const types.DirectoryEntry,
    depth_limit: u8,
    top_n: u16,
    total_size: u64,
) ![]OutputEntry {
    return collectVisibleEntries(allocator, source, depth_limit, top_n, total_size);
}

fn collectVisibleEntries(
    allocator: Allocator,
    source: []const types.DirectoryEntry,
    depth_limit: u8,
    top_n: u16,
    total_size: u64,
) ![]OutputEntry {
    if (depth_limit == 0) return try allocator.alloc(OutputEntry, 0);
    const depth_buckets = @as(usize, depth_limit);
    const buckets = try allocator.alloc(std.array_list.Managed(OutputEntry), depth_buckets);
    for (buckets) |*bucket| bucket.* = try std.array_list.Managed(OutputEntry).initCapacity(allocator, 0);
    defer {
        for (buckets) |*bucket| bucket.deinit();
        allocator.free(buckets);
    }

    try collectBuckets(source, buckets);

    var output = try std.array_list.Managed(OutputEntry).initCapacity(allocator, 64);
    for (buckets, 0..) |bucket, depth_idx| {
        if (bucket.items.len == 0) continue;
        sortBySize(bucket.items);
        const max_count = if (top_n == 0 or top_n >= bucket.items.len) bucket.items.len else @as(usize, top_n);

        for (bucket.items[0..max_count]) |entry| {
            var visible = entry;
            visible.percent = if (total_size == 0)
                0.0
            else
                (100.0 * @as(f64, @floatFromInt(entry.bytes))) / @as(f64, @floatFromInt(total_size));
            visible.depth = @intCast(depth_idx + 1);
            try output.append(visible);
        }

        if (bucket.items.len > max_count) {
            var other_size: u64 = 0;
            var other_file_count: u32 = 0;
            var other_dir_count: u32 = 0;
            for (bucket.items[max_count..]) |entry| {
                other_size += entry.bytes;
                other_file_count += entry.file_count;
                other_dir_count += entry.dir_count;
            }

            const label = try std.fmt.allocPrint(allocator, "other ({d} dirs)", .{other_dir_count + other_file_count});
            const visible_percent = if (total_size == 0)
                0.0
            else
                (100.0 * @as(f64, @floatFromInt(other_size))) / @as(f64, @floatFromInt(total_size));
            try output.append(.{
                .path = label,
                .bytes = other_size,
                .percent = visible_percent,
                .file_count = other_file_count,
                .dir_count = other_dir_count,
                .depth = @intCast(depth_idx + 1),
            });
        }
    }

    const ordered = try output.toOwnedSlice();
    sortBySize(ordered);
    return ordered;
}

fn collectBuckets(
    nodes: []const types.DirectoryEntry,
    buckets: []std.array_list.Managed(OutputEntry),
) !void {
    for (nodes) |entry| {
        if (entry.depth > 0 and entry.depth <= buckets.len) {
            const depth_idx = @as(usize, entry.depth - 1);
            try buckets[depth_idx].append(.{
                .path = entry.path,
                .bytes = entry.size_bytes,
                .percent = 0.0,
                .file_count = entry.file_count,
                .dir_count = entry.dir_count,
                .depth = entry.depth,
            });
        }
        if (entry.children.len > 0) {
            try collectBuckets(entry.children, buckets);
        }
    }
}

fn roundOneDecimal(value: f64) f64 {
    return @round(value * 10.0) / 10.0;
}

fn ageHuman(allocator: Allocator, timestamp: i64) ![]u8 {
    const now = std.time.timestamp();
    const diff = if (now > timestamp) now - timestamp else 0;
    const total: u64 = @intCast(diff);
    const d = total / 86_400;
    const h = (total % 86_400) / 3_600;
    const m = (total % 3_600) / 60;
    const s = total % 60;

    if (d > 0) return try std.fmt.allocPrint(allocator, "{d}d {d}h {d}m ago", .{ d, h, m });
    if (h > 0) return try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s ago", .{ h, m, s });
    if (m > 0) return try std.fmt.allocPrint(allocator, "{d}m {d}s ago", .{ m, s });
    return try std.fmt.allocPrint(allocator, "{d}s ago", .{s});
}

fn ageSeconds(current: i64, then: i64) u64 {
    const end = if (current > then) current else then;
    return @intCast(end - then);
}

fn formatBytes(allocator: Allocator, value: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var scaled: f64 = @floatFromInt(value);
    var unit_idx: usize = 0;
    while (scaled >= 1024.0 and unit_idx + 1 < units.len) : (unit_idx += 1) {
        scaled /= 1024.0;
    }
    return try std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ scaled, units[unit_idx] });
}

fn sortBySize(items: []OutputEntry) void {
    if (items.len < 2) return;
    var i: usize = 0;
    while (i < items.len - 1) : (i += 1) {
        var j: usize = 0;
        while (j + 1 < items.len - i) : (j += 1) {
            if (items[j].bytes < items[j + 1].bytes) {
                const tmp = items[j];
                items[j] = items[j + 1];
                items[j + 1] = tmp;
            }
        }
    }
}

fn makeBar(percent: f64) [20]u8 {
    var bar = [_]u8{' '} ** 20;
    bar[0] = '[';
    bar[19] = ']';
    const filled = @min(@as(usize, @intFromFloat((percent / 100.0) * 16.0)), 16);
    var idx: usize = 0;
    while (idx < filled and idx + 1 < bar.len - 1) : (idx += 1) {
        bar[idx] = '=';
    }
    if (filled < 16 and filled > 0) {
        bar[filled + 1] = '>';
    } else if (filled >= 16 and bar.len > 1) {
        bar[17] = '=';
    }
    return bar;
}

fn formatDateFromDays(days: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days + 719468;
    const era = if (z >= 0) @divTrunc(z, 146097) else @divTrunc(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + 3;
    const month = if (m <= 12) m else m - 12;
    const year = y + @as(i64, if (m > 12) 1 else 0) + @as(i64, 1970);
    return .{ .year = year, .month = month, .day = d };
}

pub fn formatTimestampISO(allocator: Allocator, timestamp: i64) ![]u8 {
    var secs = timestamp;
    if (secs < 0) secs = 0;
    const days = @divFloor(secs, 86_400);
    const remainder = @mod(secs, 86_400);
    const date = formatDateFromDays(days);
    const hour = @divTrunc(remainder, 3600);
    const minute = @divTrunc(@mod(remainder, 3600), 60);
    const second = @mod(remainder, 60);
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        date.year,
        date.month,
        date.day,
        hour,
        minute,
        second,
    });
}
