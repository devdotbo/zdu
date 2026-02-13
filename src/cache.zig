const std = @import("std");
const types = @import("./types.zig");
const platform = @import("./platform/generic.zig");

const Allocator = std.mem.Allocator;

const CACHE_MAGIC = [4]u8{ 'Z', 'D', 'U', '0' };
const CACHE_VERSION = 2;
const GCNT_MAGIC = [4]u8{ 'G', 'C', 'N', 'T' };

const CachedEntry = struct {
    path: []const u8,
    path_len: u16,
    size_bytes: u64,
    file_count: u32,
    dir_count: u32,
    depth: u8,
};

const CachedTreeNode = struct {
    node: *types.DirectoryEntry,
    children: std.array_list.Managed(*types.DirectoryEntry),
};

const EvictionCandidate = struct {
    path: []const u8,
    size_bytes: u64,
    mtime: i64,
};

pub fn readCache(
    allocator: Allocator,
    canonical_path: []const u8,
    path_hash: []const u8,
    config: types.Config,
) !?types.ScanResult {
    const cache_path = try cacheFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(cache_path);

    const file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
    defer file.close();

    const file_size = try file.getEndPos();
    const header_size = @sizeOf(types.CacheHeader);
    if (file_size < header_size) return null;
    if (file_size > 256 * 1024 * 1024 * 1024) return null;

    const bytes = try allocator.alloc(u8, file_size);
    defer allocator.free(bytes);

    const read = try file.readAll(bytes);
    if (read != file_size) return null;

    var cursor: usize = 0;
    var header = types.CacheHeader{
        .magic = std.mem.zeroes([4]u8),
        .version = 0,
        .timestamp = 0,
        .scan_duration_ms = 0,
        .entry_count = 0,
    };

    if (!readHeader(bytes, &cursor, file_size, &header)) return null;
    if (!std.mem.eql(u8, &header.magic, &CACHE_MAGIC)) return null;
    if (header.version != CACHE_VERSION) return null;
    if (header.timestamp <= 0) return null;
    const now = std.time.timestamp();
    if (header.timestamp > now) return null;
    if (header.entry_count == 0) return null;

    var records = try std.array_list.Managed(CachedEntry).initCapacity(allocator, try safeCastUsize(header.entry_count));
    defer {
        for (records.items) |record| allocator.free(record.path);
        records.deinit();
    }

    while (cursor < file_size) {
        if (records.items.len >= try safeCastUsize(header.entry_count)) return null;
        const rec = try parseRecord(allocator, bytes, &cursor, file_size);
        try records.append(rec);
    }

    if (records.items.len != try safeCastUsize(header.entry_count)) return null;
    if (cursor != file_size) return null;
    validateDepthSequence(records.items) catch return null;

    const root_entry = try rebuildTree(allocator, records.items);
    const volume_info = platform.getVolumeInfo(allocator, canonical_path) catch return null;

    return .{
        .path = canonical_path,
        .timestamp = header.timestamp,
        .duration_ms = header.scan_duration_ms,
        .volume_info = volume_info,
        .root_entry = root_entry,
        .entry_count = header.entry_count,
        .cache_timestamp = header.timestamp,
    };
}

pub fn writeCache(
    allocator: Allocator,
    path_hash: []const u8,
    result: *const types.ScanResult,
    config: types.Config,
) !void {
    const cache_path = try cacheFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(cache_path);

    var cache_atomic_buffer: [8192]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(cache_path, .{
        .mode = 0o600,
        .write_buffer = &cache_atomic_buffer,
    });
    errdefer af.deinit();

    var writer = &af.file_writer.interface;
    try writer.writeAll(&CACHE_MAGIC);
    try writer.writeInt(u32, CACHE_VERSION, .little);
    try writer.writeInt(i64, if (result.timestamp == 0) std.time.timestamp() else result.timestamp, .little);
    try writer.writeInt(u64, result.duration_ms, .little);
    try writer.writeInt(u64, result.entry_count, .little);

    try writeDirectory(writer, result.root_entry);
    try af.finish();

    try evictIfNeeded(allocator, config);
}

pub fn writeGencounts(
    allocator: Allocator,
    path_hash: []const u8,
    records: []const types.GencountRecord,
    config: types.Config,
) !void {
    if (records.len == 0) return;

    const gencount_path = try gencountFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(gencount_path);

    var gencount_atomic_buffer: [8192]u8 = undefined;
    var af = try std.fs.cwd().atomicFile(gencount_path, .{
        .mode = 0o600,
        .write_buffer = &gencount_atomic_buffer,
    });
    errdefer af.deinit();

    var writer = &af.file_writer.interface;
    try writer.writeAll(&GCNT_MAGIC);
    try writer.writeInt(u32, @intCast(records.len), .little);

    for (records) |record| {
        const p_len: u16 = @intCast(record.path.len);
        try writer.writeInt(u16, p_len, .little);
        if (p_len > 0) {
            try writer.writeAll(record.path);
        }
        try writer.writeInt(u64, record.value, .little);
    }

    try af.finish();
}

pub fn readGencounts(
    allocator: Allocator,
    path_hash: []const u8,
    config: types.Config,
) !?[]types.GencountRecord {
    const gencount_path = try gencountFilePath(allocator, config.cache_dir, path_hash);
    defer allocator.free(gencount_path);

    const file = std.fs.cwd().openFile(gencount_path, .{}) catch return null;
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < 8) return null;

    const bytes = try allocator.alloc(u8, file_size);
    defer allocator.free(bytes);

    const read = try file.readAll(bytes);
    if (read != file_size) return null;

    var cursor: usize = 0;
    if (cursor + 8 > bytes.len) return null;
    if (!std.mem.eql(u8, bytes[0..4], &GCNT_MAGIC)) return null;
    cursor += 4;

    const count = readIntFromSlice(u32, bytes, cursor);
    cursor += 4;

    var records = try std.array_list.Managed(types.GencountRecord).initCapacity(allocator, count);
    defer records.deinit();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (cursor + 2 > bytes.len) return null;
        const path_len = readIntFromSlice(u16, bytes, cursor);
        cursor += 2;
        if (cursor + path_len > bytes.len) return null;
        const path = try allocator.dupe(u8, bytes[cursor .. cursor + path_len]);
        cursor += path_len;

        if (cursor + 8 > bytes.len) return null;
        const value = readIntFromSlice(u64, bytes, cursor);
        cursor += 8;

        try records.append(.{ .path = path, .value = value });
    }

    if (cursor != bytes.len) return null;
    return @as(?[]types.GencountRecord, try records.toOwnedSlice());
}

fn writeDirectory(writer: anytype, node: *const types.DirectoryEntry) !void {
    const p_len: u16 = @intCast(node.path.len);
    try writer.writeInt(u16, p_len, .little);
    if (p_len > 0) {
        try writer.writeAll(node.path);
    }
    try writer.writeInt(u64, node.size_bytes, .little);
    try writer.writeInt(u32, node.file_count, .little);
    try writer.writeInt(u32, node.dir_count, .little);
    try writer.writeInt(u8, node.depth, .little);

    for (node.children) |*child| {
        try writeDirectory(writer, child);
    }
}

fn parseRecord(allocator: Allocator, bytes: []const u8, cursor: *usize, file_size: usize) !CachedEntry {
    if (cursor.* + 2 > file_size) return error.InvalidCache;
    const path_len = readIntFromSlice(u16, bytes, cursor.*);
    cursor.* += 2;

    if (cursor.* + path_len > file_size) return error.InvalidCache;
    const path = try allocator.dupe(u8, bytes[cursor.* .. cursor.* + path_len]);
    cursor.* += path_len;

    if (cursor.* + 8 > file_size) return error.InvalidCache;
    const size_bytes = readIntFromSlice(u64, bytes, cursor.*);
    cursor.* += 8;

    if (cursor.* + 4 > file_size) return error.InvalidCache;
    const file_count = readIntFromSlice(u32, bytes, cursor.*);
    cursor.* += 4;

    if (cursor.* + 4 > file_size) return error.InvalidCache;
    const dir_count = readIntFromSlice(u32, bytes, cursor.*);
    cursor.* += 4;

    if (cursor.* + 1 > file_size) return error.InvalidCache;
    const depth = bytes[cursor.*];
    cursor.* += 1;

    return .{
        .path = path,
        .path_len = path_len,
        .size_bytes = size_bytes,
        .file_count = file_count,
        .dir_count = dir_count,
        .depth = depth,
    };
}

fn readIntFromSlice(comptime T: type, bytes: []const u8, offset: usize) T {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.copyForwards(u8, &raw, bytes[offset .. offset + @sizeOf(T)]);
    return std.mem.readInt(T, &raw, .little);
}

fn validateDepthSequence(records: []const CachedEntry) !void {
    if (records.len == 0) return error.InvalidCache;
    if (records[0].depth != 0) return error.InvalidCache;
    if (records[0].path_len != 0) return error.InvalidCache;

    var stack_depths = try std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, records.len);
    defer stack_depths.deinit();
    try stack_depths.append(records[0].depth);

    for (records[1..]) |entry| {
        const parent_depth = stack_depths.getLast();
        if (entry.depth > parent_depth + 1) return error.InvalidCache;
        while (stack_depths.items.len > 0 and entry.depth <= stack_depths.getLast()) {
            _ = stack_depths.pop();
        }
        if (stack_depths.items.len == 0) return error.InvalidCache;
        try stack_depths.append(entry.depth);
    }
}

fn readHeader(bytes: []const u8, cursor: *usize, file_size: usize, out: *types.CacheHeader) bool {
    if (file_size < @sizeOf(types.CacheHeader)) return false;
    std.mem.copyForwards(u8, &out.magic, bytes[cursor.* .. cursor.* + 4]);
    cursor.* += 4;
    if (cursor.* + 4 > file_size) return false;
    out.version = readIntFromSlice(u32, bytes, cursor.*);
    cursor.* += 4;
    if (cursor.* + 8 > file_size) return false;
    out.timestamp = readIntFromSlice(i64, bytes, cursor.*);
    cursor.* += 8;
    if (cursor.* + 8 > file_size) return false;
    out.scan_duration_ms = readIntFromSlice(u64, bytes, cursor.*);
    cursor.* += 8;
    if (cursor.* + 8 > file_size) return false;
    out.entry_count = readIntFromSlice(u64, bytes, cursor.*);
    cursor.* += 8;
    return true;
}

fn rebuildTree(allocator: Allocator, entries: []const CachedEntry) !*types.DirectoryEntry {
    var nodes = try allocator.alloc(CachedTreeNode, entries.len);

    for (entries, 0..) |entry, idx| {
        const rel_path = try allocator.dupe(u8, entry.path);
        const node = try allocator.create(types.DirectoryEntry);
        node.* = .{
            .path = rel_path,
            .size_bytes = entry.size_bytes,
            .file_count = entry.file_count,
            .dir_count = entry.dir_count,
            .depth = entry.depth,
            .children = &[_]types.DirectoryEntry{},
        };
        nodes[idx] = .{
            .node = node,
            .children = try std.array_list.Managed(*types.DirectoryEntry).initCapacity(allocator, 0),
        };
    }

    var parent_stack = try std.array_list.Managed(usize).initCapacity(allocator, 0);
    defer parent_stack.deinit();
    try parent_stack.append(0);

    for (entries, 0..) |entry, idx| {
        if (idx == 0) continue;
        while (parent_stack.items.len > 0 and entry.depth <= entries[parent_stack.getLast()].depth) {
            _ = parent_stack.pop();
        }
        if (parent_stack.items.len == 0) return error.InvalidCache;
        const parent_idx = parent_stack.getLast();
        if (entry.depth != entries[parent_idx].depth + 1) return error.InvalidCache;
        try nodes[parent_idx].children.append(nodes[idx].node);
        try parent_stack.append(idx);
    }

    var reverse = entries.len;
    while (reverse > 0) {
        reverse -= 1;
        const current = &nodes[reverse];
        if (current.children.items.len > 0) {
            const children_slice = try allocator.alloc(types.DirectoryEntry, current.children.items.len);
            for (current.children.items, 0..) |child, child_i| {
                children_slice[child_i] = child.*;
            }
            current.node.children = children_slice;
        } else {
            current.node.children = &[_]types.DirectoryEntry{};
        }
        current.children.deinit();
    }

    return nodes[0].node;
}

pub fn cacheFilePath(allocator: Allocator, cache_dir: []const u8, path_hash: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.zdu", .{ cache_dir, path_hash });
}

pub fn gencountFilePath(allocator: Allocator, cache_dir: []const u8, path_hash: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.gencount", .{ cache_dir, path_hash });
}

pub fn pidFilePath(allocator: Allocator, cache_dir: []const u8, path_hash: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.pid", .{ cache_dir, path_hash });
}

pub fn sockFilePath(allocator: Allocator, cache_dir: []const u8, path_hash: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.sock", .{ cache_dir, path_hash });
}

pub fn logFilePath(
    allocator: Allocator,
    log_dir: []const u8,
    path_hash: []const u8,
    timestamp: i64,
) ![]const u8 {
    const ts = try formatLogTimestamp(allocator, timestamp);
    defer allocator.free(ts);
    return try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.log", .{ log_dir, path_hash, ts });
}

fn formatLogTimestamp(allocator: Allocator, timestamp: i64) ![]const u8 {
    var secs = timestamp;
    if (secs < 0) secs = 0;
    const days = @divFloor(secs, 86_400);
    const remainder = @mod(secs, 86_400);
    const date = formatDateFromDays(days);
    const hour = @divTrunc(remainder, 3600);
    const minute = @divTrunc(@mod(remainder, 3600), 60);
    const second = @mod(remainder, 60);
    return try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        date.year,
        date.month,
        date.day,
        hour,
        minute,
        second,
    });
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
    const year = y + (if (m > 12) @as(i64, 1) else @as(i64, 0)) + @as(i64, 1970);
    return .{ .year = year, .month = month, .day = d };
}

fn safeCastUsize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.InvalidCache;
}

pub fn evictIfNeeded(allocator: Allocator, config: types.Config) !void {
    var dir = std.fs.cwd().openDir(config.cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const max_bytes = config.max_cache_bytes;
    if (max_bytes == 0) return;

    var candidates = try std.array_list.Managed(EvictionCandidate).initCapacity(std.heap.page_allocator, 0);
    defer candidates.deinit();

    var it = dir.iterate();
    var total: u64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zdu")) continue;

        const name = try std.fs.path.join(std.heap.page_allocator, &.{ config.cache_dir, entry.name });
        defer std.heap.page_allocator.free(name);

        const stat = dir.statFile(entry.name) catch continue;
        const size_u64 = @as(u64, @intCast(stat.size));
        const size_and_mtime = try parseMTime(entry, dir);
        const mtime = if (size_and_mtime) |m| m else 0;

        try candidates.append(.{
            .path = try allocator.dupe(u8, name),
            .size_bytes = size_u64,
            .mtime = mtime,
        });
        total += size_u64;
    }

    if (total <= max_bytes) {
        for (candidates.items) |entry| allocator.free(entry.path);
        return;
    }

    std.mem.sort(EvictionCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: EvictionCandidate, b: EvictionCandidate) bool {
            return a.mtime < b.mtime;
        }
    }.lessThan);

    var current_total = total;
    for (candidates.items) |entry| {
        if (current_total <= max_bytes) {
            allocator.free(entry.path);
            continue;
        }

        std.fs.cwd().deleteFile(entry.path) catch {};
        const base = std.fs.path.basename(entry.path);
        const stem = std.fs.path.stem(base);

        const gencount = gencountFilePath(allocator, config.cache_dir, stem) catch null;
        if (gencount) |path| {
            defer allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        }

        const pid_file = pidFilePath(allocator, config.cache_dir, stem) catch null;
        if (pid_file) |path| {
            defer allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        }

        const sock_file = sockFilePath(allocator, config.cache_dir, stem) catch null;
        if (sock_file) |path| {
            defer allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        }

        current_total -= entry.size_bytes;
        allocator.free(entry.path);
    }
}

fn parseMTime(entry: std.fs.Dir.Entry, dir: std.fs.Dir) !?i64 {
    const stat = dir.statFile(entry.name) catch return null;
    return @as(i64, @intCast(stat.mtime));
}
