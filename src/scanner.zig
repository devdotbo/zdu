const std = @import("std");
const types = @import("./types.zig");
const cache = @import("./cache.zig");
const pathmod = @import("./path.zig");
const platform = @import("./platform/generic.zig");

const Allocator = std.mem.Allocator;

pub const ScanSummary = struct {
    result: types.ScanResult,
    had_warnings: bool,
};

const ScanTaskOptions = struct {
    cross_mount: bool,
    progress: ?*types.ScanProgressState = null,
    canceled: ?*std.atomic.Value(bool) = null,
    verbose: bool = false,
};

const EMPTY_CHILDREN = [_]types.DirectoryEntry{};

const StackFrame = struct {
    abs_path: []const u8,
    rel_path: []const u8,
    depth: u8,
    node: *types.DirectoryEntry,
    iter: platform.DirIterator,
    children: std.ArrayList(*types.DirectoryEntry),
    had_permission_warning: bool,
};

pub fn scan(
    allocator: Allocator,
    path: []const u8,
    config: types.Config,
    cross_mount: bool,
) !ScanSummary {
    _ = config;
    return scanWithProgress(allocator, path, cross_mount, .{});
}

pub fn scanWithProgress(
    allocator: Allocator,
    path: []const u8,
    cross_mount: bool,
    options: ScanTaskOptions,
) !ScanSummary {
    if (options.verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("[DEBUG] scan: starting {s}\n", .{path});
    }

    const started = std.time.milliTimestamp();
    var warnings: u32 = 0;
    const started_seconds = std.time.timestamp();

    if (options.progress) |progress| {
        progress.* = .init(started_seconds);
        progress.state.store(@intFromEnum(types.SessionState.scanning), .release);
        progress.cancel_requested.store(false, .release);
        progress.complete.store(false, .release);
        progress.errors_count.store(0, .release);
        progress.files_scanned.store(0, .release);
        progress.dirs_scanned.store(0, .release);
        progress.bytes_scanned.store(0, .release);
        progress.estimated_remaining_seconds.store(-1, .release);
        progress.percent_complete_x10.store(-1, .release);
    }

    var active = if (options.progress) |p| p else null;
    const volume_info = try platform.getVolumeInfo(path);
    const root_device_id: ?u64 = null;

    var root_iter = try platform.openDirIterator(allocator, path);
    const root_node = try createNode(allocator, "", 0);

    var stack = std.ArrayList(StackFrame).init(allocator);
    defer stack.deinit();

    try stack.append(.{
        .abs_path = try allocator.dupe(u8, path),
        .rel_path = "",
        .depth = 0,
        .node = root_node,
        .iter = root_iter,
        .children = std.ArrayList(*types.DirectoryEntry).init(allocator),
        .had_permission_warning = false,
    });

    while (stack.items.len > 0) {
        if (active) |progress| {
            if (progress.cancel_requested.load(.acquire)) {
                return error.Canceled;
            }
        }

        const frame = &stack.items[stack.items.len - 1];
        const next_entry = frame.iter.next() catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                if (active) |progress| {
                    _ = progress.errors_count.fetchAdd(1, .monotonic);
                }
                warnings += 1;
                frame.had_permission_warning = true;
                if (options.verbose) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("[DEBUG] scan: skipped unreadable entry in {s}\n", .{frame.abs_path});
                }
                continue;
            },
            else => return err,
        };

        if (next_entry == null) {
            const finished = stack.pop();
            try finalizeFrameChildren(allocator, &finished);
            finished.iter.deinit();

            if (stack.items.len > 0) {
                const parent = &stack.items[stack.items.len - 1];
                parent.node.size_bytes += finished.node.size_bytes;
                parent.node.file_count += finished.node.file_count;
                parent.node.dir_count += finished.node.dir_count + 1;
                if (active) |progress| {
                    _ = progress.dirs_scanned.fetchAdd(1, .monotonic);
                    progress.bytes_scanned.fetchAdd(finished.node.size_bytes, .monotonic);
                    progress.files_scanned.fetchAdd(finished.node.file_count, .monotonic);
                }
                if (finished.had_permission_warning) warnings += 1;
            } else {
                if (finished.had_permission_warning) warnings += 1;
            }
            if (active) |progress| {
                updateProgress(progress, volume_info.used_bytes, started_seconds);
            }
            continue;
        }

        const entry = next_entry.?;
        switch (entry.kind) {
            .file => {
                frame.node.size_bytes += entry.size;
                frame.node.file_count += 1;
                if (active) |progress| {
                    _ = progress.files_scanned.fetchAdd(1, .monotonic);
                    progress.bytes_scanned.fetchAdd(entry.size, .monotonic);
                    updateProgress(progress, volume_info.used_bytes, started_seconds);
                }
            },
            .directory => {
                if (!cross_mount) {
                    if (root_device_id) |root_dev| {
                        if (entry.device_id != 0 and entry.device_id != root_dev) {
                            if (active) |progress| {
                                _ = progress.errors_count.fetchAdd(1, .monotonic);
                            }
                            warnings += 1;
                            continue;
                        }
                    }
                }

                const child_rel = if (frame.rel_path.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ frame.rel_path, entry.name });

                const child_abs = try joinPath(allocator, frame.abs_path, entry.name);
                const child_node = try createNode(allocator, child_rel, frame.depth + 1);
                const child_iter = platform.openDirIterator(allocator, child_abs) catch {
                    if (active) |progress| {
                        _ = progress.errors_count.fetchAdd(1, .monotonic);
                    }
                    warnings += 1;
                    if (options.verbose) {
                        const stderr = std.io.getStdErr().writer();
                        try stderr.print("[DEBUG] scan: skipped directory {s}\n", .{child_abs});
                    }
                    continue;
                };

                try frame.children.append(child_node);
                try stack.append(.{
                    .abs_path = child_abs,
                    .rel_path = child_rel,
                    .depth = frame.depth + 1,
                    .node = child_node,
                    .iter = child_iter,
                    .children = std.ArrayList(*types.DirectoryEntry).init(allocator),
                    .had_permission_warning = false,
                });
                if (active) |progress| {
                    _ = progress.dirs_scanned.fetchAdd(1, .monotonic);
                }
            },
            .symbolic_link => {
                if (active) |progress| {
                    _ = progress.errors_count.fetchAdd(1, .monotonic);
                }
                warnings += 1;
            },
            else => {
                if (active) |progress| {
                    _ = progress.errors_count.fetchAdd(1, .monotonic);
                }
                warnings += 1;
            },
        }
    }

    const duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - started));
    const count = countEntries(root_node);
    root_node.children = if (root_node.children.len == 0) &EMPTY_CHILDREN else root_node.children;

    const result = types.ScanResult{
        .path = path,
        .timestamp = std.time.timestamp(),
        .duration_ms = duration_ms,
        .volume_info = volume_info,
        .root_entry = root_node,
        .entry_count = count,
    };

    if (options.verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(
            "[DEBUG] scan: completed {s} duration_ms={d} entries={d} warnings={d}\n",
            .{ path, duration_ms, warnings },
        );
    }

    if (active) |progress| {
        progress.state.store(@intFromEnum(types.SessionState.done), .release);
        progress.complete.store(true, .release);
        progress.percent_complete_x10.store(1000, .release);
        progress.estimated_remaining_seconds.store(0, .release);
    }

    return .{
        .result = result,
        .had_warnings = warnings > 0,
    };
}

pub fn partialScan(
    allocator: Allocator,
    path: []const u8,
    _stale_subtrees: []const []const u8,
    config: types.Config,
    cross_mount: bool,
    progress: ?*types.ScanProgressState,
    verbose: bool,
) !ScanSummary {
    if (verbose) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("[DEBUG] partial scan start path={s} stale_subtrees={d}\n", .{ path, _stale_subtrees.len });
    }

    if (_stale_subtrees.len == 0) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("[DEBUG] partial scan fallback to full scan (no stale subtrees)\n", .{});
        }
        return scanWithProgress(allocator, path, cross_mount, .{
            .progress = progress,
            .canceled = if (progress) |state| &state.cancel_requested else null,
            .cross_mount = cross_mount,
            .verbose = verbose,
        });
    }

    var normalized_stale = std.ArrayList([]const u8).init(allocator);
    defer {
        for (normalized_stale.items) |entry| allocator.free(entry);
        normalized_stale.deinit();
    }

    for (_stale_subtrees) |raw_entry| {
        const normalized = try normalizeSubtreePath(allocator, raw_entry);
        if (!hasPath(normalized_stale.items, normalized)) {
            try normalized_stale.append(allocator.dupe(u8, normalized));
        }
        allocator.free(normalized);
    }

    if (normalized_stale.items.len == 0) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("[DEBUG] partial scan fallback to full scan (stale list normalized empty)\n", .{});
        }
        return scanWithProgress(allocator, path, cross_mount, .{
            .progress = progress,
            .canceled = if (progress) |state| &state.cancel_requested else null,
            .cross_mount = cross_mount,
            .verbose = verbose,
        });
    }

    for (normalized_stale.items) |entry| {
        if (entry.len == 0) {
            if (verbose) {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("[DEBUG] partial scan fallback to full scan (root dirty)\n", .{});
            }
            return scanWithProgress(allocator, path, cross_mount, .{
                .progress = progress,
                .canceled = if (progress) |state| &state.cancel_requested else null,
                .cross_mount = cross_mount,
                .verbose = verbose,
            });
        }
    }

    if (containsRoot(normalized_stale.items)) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("[DEBUG] partial scan fallback to full scan (root already stale)\n", .{});
        }
        return scanWithProgress(allocator, path, cross_mount, .{
            .progress = progress,
            .canceled = if (progress) |state| &state.cancel_requested else null,
            .cross_mount = cross_mount,
            .verbose = verbose,
        });
    }

    const hash = try pathmod.hashPath(allocator, path);
    defer allocator.free(hash);

    const cached = cache.readCache(allocator, path, hash, config) catch null;
    if (cached == null) {
        if (verbose) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("[DEBUG] partial scan fallback to full scan (missing cached baseline)\n", .{});
        }
        return scanWithProgress(allocator, path, cross_mount, .{
            .progress = progress,
            .canceled = if (progress) |state| &state.cancel_requested else null,
            .cross_mount = cross_mount,
            .verbose = verbose,
        });
    }

    var replacements = std.ArrayList(ReplacementSubtree).init(allocator);
    defer replacements.deinit();

    var had_warnings = false;

    for (normalized_stale.items) |entry| {
        const subtree_path = if (entry.len == 0) path else try std.fs.path.join(allocator, &.{ path, entry });
        defer if (entry.len != 0) allocator.free(subtree_path);

        const scanned = try scanWithProgress(allocator, subtree_path, cross_mount, .{
            .progress = null,
            .canceled = if (progress) |state| &state.cancel_requested else null,
            .cross_mount = cross_mount,
            .verbose = verbose,
        });
        had_warnings = had_warnings or scanned.had_warnings;

        const subtree_depth = pathDepth(entry);
        const replacement = try relocateSubtree(allocator, scanned.result.root_entry, entry, subtree_depth);
        try replacements.append(.{
            .path = try allocator.dupe(u8, entry),
            .node = replacement,
        });
    }

    const merged_root = try mergeSubtrees(allocator, cached.result.root_entry, replacements.items);
    const result = types.ScanResult{
        .path = cached.result.path,
        .timestamp = std.time.timestamp(),
        .duration_ms = cached.result.duration_ms,
        .volume_info = cached.result.volume_info,
        .root_entry = merged_root.node,
        .entry_count = countEntries(merged_root.node),
    };

    return .{
        .result = result,
        .had_warnings = had_warnings,
    };
}

const MergeResult = struct {
    node: *types.DirectoryEntry,
    changed: bool,
};

const ReplacementSubtree = struct {
    path: []const u8,
    node: *types.DirectoryEntry,
};

fn hasPath(list: []const []const u8, target: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, target)) return true;
    }
    return false;
}

fn containsRoot(list: []const []const u8) bool {
    for (list) |path| {
        if (path.len == 0) return true;
    }
    return false;
}

fn normalizeSubtreePath(allocator: Allocator, raw: []const u8) ![]const u8 {
    var start: usize = 0;
    while (start < raw.len and raw[start] == '/') start += 1;

    var end: usize = raw.len;
    while (end > start and raw[end - 1] == '/') end -= 1;

    if (end <= start) return try allocator.dupe(u8, "");

    const trimmed = raw[start..end];
    if (trimmed.len == 1 and std.mem.eql(u8, trimmed, ".")) return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, trimmed);
}

fn pathDepth(path: []const u8) u16 {
    if (path.len == 0) return 0;

    var count: u16 = 1;
    for (path) |ch| {
        if (ch == '/') count += 1;
    }
    return count;
}

fn combinePath(allocator: Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    if (prefix.len == 0) return try allocator.dupe(u8, path);
    if (path.len == 0) return try allocator.dupe(u8, prefix);
    return std.fs.path.join(allocator, &.{ prefix, path });
}

fn relocateSubtree(
    allocator: Allocator,
    node: *types.DirectoryEntry,
    base_path: []const u8,
    base_depth: u16,
) !*types.DirectoryEntry {
    var new_node = try allocator.create(types.DirectoryEntry);
    const relocated_path = try combinePath(allocator, base_path, node.path);
    const relocated_depth = @min(@as(u16, 255), base_depth + node.depth);
    const depth = @as(u8, @min(255, relocated_depth));

    new_node.* = .{
        .path = relocated_path,
        .size_bytes = node.size_bytes,
        .file_count = node.file_count,
        .dir_count = node.dir_count,
        .depth = depth,
        .children = &EMPTY_CHILDREN,
    };

    if (node.children.len == 0) return new_node;

    var children = std.ArrayList(types.DirectoryEntry).init(allocator);
    defer children.deinit();

    for (node.children) |entry| {
        const child = try relocateSubtree(allocator, entry, relocated_path, relocated_depth);
        try children.append(child.*);
    }

    new_node.children = try children.toOwnedSlice();
    return new_node;
}

fn mergeSubtrees(
    allocator: Allocator,
    base: *types.DirectoryEntry,
    replacements: []const ReplacementSubtree,
) !MergeResult {
    if (findReplacement(base.path, replacements)) |replacement| {
        return .{ .node = replacement, .changed = true };
    }

    var merged_children = std.ArrayList(types.DirectoryEntry).init(allocator);

    var out_size = base.size_bytes;
    var out_file_count = base.file_count;
    var out_dir_count = base.dir_count;
    var changed = false;

    for (base.children) |child| {
        const merged_child = try mergeSubtrees(allocator, child, replacements);
        try merged_children.append(merged_child.node.*);

        if (merged_child.changed) {
            changed = true;
            if (out_size >= child.size_bytes) {
                out_size -= child.size_bytes;
            } else {
                out_size = 0;
            }
            out_size += merged_child.node.size_bytes;

            if (out_file_count >= child.file_count) {
                out_file_count -= child.file_count;
            } else {
                out_file_count = 0;
            }
            out_file_count += merged_child.node.file_count;

            if (out_dir_count >= child.dir_count) {
                out_dir_count -= child.dir_count;
            } else {
                out_dir_count = 0;
            }
            out_dir_count += merged_child.node.dir_count;
        }
    }

    const merged = try allocator.create(types.DirectoryEntry);
    const merged_children_items = if (merged_children.items.len == 0) blk: {
        merged_children.deinit();
        break :blk &EMPTY_CHILDREN;
    } else blk: {
        break :blk try merged_children.toOwnedSlice();
    };

    merged.* = .{
        .path = base.path,
        .size_bytes = out_size,
        .file_count = out_file_count,
        .dir_count = out_dir_count,
        .depth = base.depth,
        .children = merged_children_items,
    };

    return .{ .node = merged, .changed = changed };
}

fn findReplacement(path: []const u8, replacements: []const ReplacementSubtree) ?*types.DirectoryEntry {
    for (replacements) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            return entry.node;
        }
    }
    return null;
}

fn createNode(allocator: Allocator, path: []const u8, depth: u8) !*types.DirectoryEntry {
    const node = try allocator.create(types.DirectoryEntry);
    node.* = .{
        .path = path,
        .size_bytes = 0,
        .file_count = 0,
        .dir_count = 0,
        .depth = depth,
        .children = &EMPTY_CHILDREN,
    };
    return node;
}

fn finalizeFrameChildren(allocator: Allocator, frame: *StackFrame) !void {
    if (frame.children.items.len == 0) {
        frame.node.children = &EMPTY_CHILDREN;
        frame.children.deinit();
        return;
    }

    const children_slice = try allocator.alloc(types.DirectoryEntry, frame.children.items.len);
    for (frame.children.items, 0..) |child_ptr, idx| {
        children_slice[idx] = child_ptr.*;
    }
    frame.node.children = children_slice;
    frame.children.deinit();
}

fn joinPath(allocator: Allocator, left: []const u8, right: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ left, right });
}

fn countEntries(node: *types.DirectoryEntry) u64 {
    var count: u64 = 1;
    for (node.children) |*child| {
        count += countEntries(child);
    }
    return count;
}

fn updateProgress(progress: *types.ScanProgressState, used_bytes: u64, started_seconds: i64) void {
    if (used_bytes == 0) return;
    const now = std.time.timestamp();
    const elapsed = now - started_seconds;
    if (elapsed <= 0) return;

    const bytes_scanned = progress.bytes_scanned.load(.acquire);
    const fraction = if (used_bytes > 0)
        @as(f64, @floatFromInt(bytes_scanned)) / @as(f64, @floatFromInt(used_bytes))
    else
        0.0;

    if (fraction > 0.0 and fraction <= 1.0) {
        const eta = @as(f64, @floatFromInt(elapsed)) * (1.0 / fraction - 1.0);
        const clamped = if (eta < 0.0) 0.0 else eta;
        progress.estimated_remaining_seconds.store(@as(i32, @intFromFloat(clamped)), .release);
        const pct = @as(f32, @floatCast((fraction * 100.0) * 10.0));
        if (pct >= 0.0 and pct <= 1000.0) {
            progress.percent_complete_x10.store(@as(i32, @intFromFloat(pct)), .release);
        }
    }
}
