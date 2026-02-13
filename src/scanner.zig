const std = @import("std");
const types = @import("./types.zig");
const platform = @import("./platform/generic.zig");

const Allocator = std.mem.Allocator;

pub const ScanSummary = struct {
    result: types.ScanResult,
    had_warnings: bool,
};

const StackFrame = struct {
    abs_path: []const u8,
    rel_path: []const u8,
    depth: u8,
    node: *types.DirectoryEntry,
    iter: platform.DirIterator,
    children: std.ArrayList(*types.DirectoryEntry),
    had_permission_warning: bool,
};

const EMPTY_CHILDREN = [_]types.DirectoryEntry{};

pub fn scan(
    allocator: Allocator,
    path: []const u8,
    config: types.Config,
    cross_mount: bool,
) !ScanSummary {
    _ = config;

    const started = std.time.milliTimestamp();
    var warnings: u32 = 0;

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
        const frame = &stack.items[stack.items.len - 1];
        const next_entry = frame.iter.next() catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
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
                if (finished.had_permission_warning) warnings += 1;
            } else {
                if (finished.had_permission_warning) warnings += 1;
            }
            continue;
        }

        const entry = next_entry.?;
        switch (entry.kind) {
            .file => {
                frame.node.size_bytes += entry.size;
                frame.node.file_count += 1;
            },
            .directory => {
                if (!cross_mount) {
                    if (root_device_id) |root_dev| {
                        if (entry.device_id != 0 and entry.device_id != root_dev) {
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
            },
            .symbolic_link => {
                warnings += 1;
            },
            else => {
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
        .volume_info = try platform.getVolumeInfo(path),
        .root_entry = root_node,
        .entry_count = count,
    };

    return .{
        .result = result,
        .had_warnings = warnings > 0,
    };
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
