const std = @import("std");
const types = @import("./types.zig");
const platform = @import("./platform/generic.zig");

const Allocator = std.mem.Allocator;

const CACHE_MAGIC = [4]u8{ 'Z', 'G', 'D', 'U' };
const CACHE_VERSION = 1;

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
    children: std.ArrayList(*types.DirectoryEntry),
};

const EvictionCandidate = struct {
    path: []const u8,
    size_bytes: u64,
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

    var records = try std.ArrayList(CachedEntry).initCapacity(allocator, try safeCastUsize(header.entry_count));
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
    const volume_info = platform.getVolumeInfo(canonical_path) catch return null;

    _ = allocator;

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

    var af = try std.fs.cwd().atomicFile(cache_path, .{ .mode = 0o600 });
    errdefer af.deinit();

    var writer = af.file.writer();
    try writer.writeAll(&CACHE_MAGIC);
    try writer.writeInt(u32, CACHE_VERSION, .little);
    try writer.writeInt(i64, if (result.timestamp == 0) std.time.timestamp() else result.timestamp, .little);
    try writer.writeInt(u64, result.duration_ms, .little);
    try writer.writeInt(u64, result.entry_count, .little);

    try writeDirectory(writer, result.root_entry);
    try af.finish();

    try evictIfNeeded(allocator, config);
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
    const path_len = std.mem.readInt(u16, bytes[cursor.* .. cursor.* + 2], .little);
    cursor.* += 2;

    if (cursor.* + path_len > file_size) return error.InvalidCache;
    const path = try allocator.dupe(u8, bytes[cursor.* .. cursor.* + path_len]);
    cursor.* += path_len;

    if (cursor.* + 8 > file_size) return error.InvalidCache;
    const size_bytes = std.mem.readInt(u64, bytes[cursor.* .. cursor.* + 8], .little);
    cursor.* += 8;

    if (cursor.* + 4 > file_size) return error.InvalidCache;
    const file_count = std.mem.readInt(u32, bytes[cursor.* .. cursor.* + 4], .little);
    cursor.* += 4;

    if (cursor.* + 4 > file_size) return error.InvalidCache;
    const dir_count = std.mem.readInt(u32, bytes[cursor.* .. cursor.* + 4], .little);
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

fn validateDepthSequence(records: []const CachedEntry) !void {
    if (records.len == 0) return error.InvalidCache;
    if (records[0].depth != 0) return error.InvalidCache;
    if (records[0].path_len != 0) return error.InvalidCache;

    var stack_depths = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, records.len);
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
    out.version = std.mem.readInt(u32, bytes[cursor.* .. cursor.* + 4], .little);
    cursor.* += 4;
    if (cursor.* + 8 > file_size) return false;
    out.timestamp = std.mem.readInt(i64, bytes[cursor.* .. cursor.* + 8], .little);
    cursor.* += 8;
    if (cursor.* + 8 > file_size) return false;
    out.scan_duration_ms = std.mem.readInt(u64, bytes[cursor.* .. cursor.* + 8], .little);
    cursor.* += 8;
    if (cursor.* + 8 > file_size) return false;
    out.entry_count = std.mem.readInt(u64, bytes[cursor.* .. cursor.* + 8], .little);
    cursor.* += 8;
    return true;
}

fn rebuildTree(
    allocator: Allocator,
    entries: []const CachedEntry,
) !*types.DirectoryEntry {
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
            .children = std.ArrayList(*types.DirectoryEntry).init(allocator),
        };
    }

    var parent_stack = std.ArrayList(usize).init(allocator);
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

fn cacheFilePath(allocator: Allocator, cache_dir: []const u8, path_hash: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}.zgdu", .{ cache_dir, path_hash });
}

fn safeCastUsize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.InvalidCache;
}

pub fn evictIfNeeded(allocator: Allocator, config: types.Config) !void {
    _ = allocator;
    var dir = std.fs.cwd().openDir(config.cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const max_bytes = config.max_cache_bytes;
    if (max_bytes == 0) return;

    var candidates = std.ArrayList(EvictionCandidate).init(std.heap.page_allocator);
    defer candidates.deinit();

    var it = dir.iterate();
    var total: u64 = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
    if (!std.mem.endsWith(u8, entry.name, ".zgdu")) continue;

    const name = try std.fs.path.join(std.heap.page_allocator, &.{ config.cache_dir, entry.name });
    defer std.heap.page_allocator.free(name);

    const stat = dir.statFile(entry.name) catch continue;
    const size_u64 = @as(u64, @intCast(stat.size));
    total += size_u64;
    try candidates.append(.{
        .path = try allocator.dupe(u8, name),
        .size_bytes = size_u64,
    });
    }

    if (total <= max_bytes) {
        for (candidates.items) |entry| allocator.free(entry.path);
        return;
    }

    std.mem.sort(EvictionCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: EvictionCandidate, b: EvictionCandidate) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    var current_total = total;
    for (candidates.items) |entry| {
        if (current_total <= max_bytes) break;

        std.fs.cwd().deleteFile(entry.path) catch {};
        const base = std.fs.path.basename(entry.path);
        const stem = std.fs.path.stem(base);
        var buf: [512]u8 = undefined;
        const gencount = try std.fmt.bufPrint(&buf, "{s}/{s}.gencount", .{ config.cache_dir, stem });
        const pid_file = try std.fmt.bufPrint(&buf, "{s}/{s}.pid", .{ config.cache_dir, stem });
        const sock_file = try std.fmt.bufPrint(&buf, "{s}/{s}.sock", .{ config.cache_dir, stem });

        std.fs.cwd().deleteFile(gencount) catch {};
        std.fs.cwd().deleteFile(pid_file) catch {};
        std.fs.cwd().deleteFile(sock_file) catch {};

        current_total -= entry.size_bytes;
    }

    for (candidates.items) |entry| allocator.free(entry.path);
}
