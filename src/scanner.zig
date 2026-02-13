const std = @import("std");
const types = @import("./types.zig");
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
) !ScanSummary {
    _ = _stale_subtrees;
    return scanWithProgress(allocator, path, cross_mount, .{
        .progress = progress,
        .canceled = if (progress) |state| &state.cancel_requested else null,
        .cross_mount = cross_mount,
    });
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
