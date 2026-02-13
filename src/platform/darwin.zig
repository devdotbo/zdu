const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sys/mount.h");
    @cInclude("sys/resource.h");
});

pub const DirEntry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    size: u64,
    device_id: u64,
};

pub const DirIterator = struct {
    dir: std.fs.Dir,
    iterator: std.fs.Dir.Iterator,
    allocator: std.mem.Allocator,

    pub fn next(self: *DirIterator) !?DirEntry {
        const entry = try self.iterator.next() orelse return null;

        var size: u64 = 0;
        const stat = self.dir.statFile(entry.name) catch null;
        if (stat) |entry_stat| {
            size = switch (entry_stat.kind) {
                .file, .character_device, .block_device, .named_pipe, .unix_domain_socket, .sym_link => entry_stat.size,
                else => 0,
            };
        }

        return .{
            .name = try self.allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .size = size,
            .device_id = 0,
        };
    }

    pub fn deinit(self: *DirIterator) void {
        self.dir.close();
    }
};

pub fn openDirIterator(allocator: std.mem.Allocator, path: []const u8) !DirIterator {
    const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    return .{
        .dir = dir,
        .iterator = dir.iterate(),
        .allocator = allocator,
    };
}

pub fn getVolumeInfo(allocator: Allocator, path: []const u8) !types.VolumeInfo {
    var fs = std.mem.zeroes(c.struct_statfs);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (c.statfs(path_z, &fs) != 0) {
        return error.StatFSFailed;
    }

    const total = fs.f_blocks * @as(@TypeOf(fs.f_bsize), fs.f_bsize);
    const free = fs.f_bavail * @as(@TypeOf(fs.f_bsize), fs.f_bsize);
    const used = if (total >= free) total - free else 0;

    const fs_type = if (std.mem.startsWith(u8, &fs.f_fstypename, "apfs"))
        types.FsType.apfs
    else if (std.mem.startsWith(u8, &fs.f_fstypename, "hfs"))
        types.FsType.hfsplus
    else
        types.FsType.other;

    const fs_id = if (std.mem.startsWith(u8, &fs.f_fstypename, "hfs"))
        "hfs+"
    else
        "other";

    return .{
        .mount_point = "/",
        .fs_type = fs_type,
        .fs_identifier = fs_id,
        .total_bytes = @intCast(total),
        .used_bytes = @intCast(used),
        .free_bytes = @intCast(free),
    };
}

pub fn getRecursiveGencount(allocator: Allocator, path: []const u8) !?u64 {
    const fs = getVolumeInfo(allocator, path) catch return null;
    if (fs.fs_type != .apfs and fs.fs_type != .hfsplus) return null;

    const records = getSubtreeGencounts(std.heap.page_allocator, path, 0) catch return null;
    defer {
        for (records) |record| {
            std.heap.page_allocator.free(record.path);
        }
        std.heap.page_allocator.free(records);
    }
    if (records.len == 0) return null;

    std.mem.sort(types.GencountRecord, records, {}, struct {
        fn lessThan(_: void, a: types.GencountRecord, b: types.GencountRecord) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    var digest: u64 = 0xcbf29ce484222325;
    for (records) |record| {
        for (record.path) |byte| {
            digest ^= byte;
            digest +%= 0x9e3779b97f4a7c15;
            digest = (digest << 6) +% (digest >> 2);
        }
        digest ^= record.value;
        digest +%= record.value;
    }

    return digest;
}

pub fn getSubtreeGencounts(
    allocator: Allocator,
    path: []const u8,
    depth: usize,
) !?[]types.GencountRecord {
    const fs = getVolumeInfo(allocator, path) catch return null;
    if (fs.fs_type != .apfs and fs.fs_type != .hfsplus) return null;

    const StackFrame = struct {
        abs_path: []const u8,
        rel_path: []const u8,
        level: usize,
    };

    var records = try std.array_list.Managed(types.GencountRecord).initCapacity(allocator, 0);
    var stack = try std.array_list.Managed(StackFrame).initCapacity(allocator, 0);
    defer {
        for (stack.items) |frame| {
            allocator.free(frame.abs_path);
            allocator.free(frame.rel_path);
        }
        stack.deinit();
    }

    const root_abs = try allocator.dupe(u8, path);
    const root_rel = try allocator.dupe(u8, "");
    try stack.append(.{
        .abs_path = root_abs,
        .rel_path = root_rel,
        .level = 0,
    });

    while (stack.items.len > 0) {
        const frame = stack.pop().?;
        const path_token = dirGencountRecord(allocator, frame.abs_path, frame.rel_path) catch {
            allocator.free(frame.abs_path);
            allocator.free(frame.rel_path);
            continue;
        };
        try records.append(path_token);

        if (depth != 0 and frame.level >= depth) {
            allocator.free(frame.abs_path);
            allocator.free(frame.rel_path);
            continue;
        }

        var it = openDirIterator(allocator, frame.abs_path) catch {
            allocator.free(frame.abs_path);
            allocator.free(frame.rel_path);
            continue;
        };
        defer it.deinit();

        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;

            const child_abs = try std.fs.path.join(allocator, &.{ frame.abs_path, entry.name });
            const child_rel = if (frame.rel_path.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ frame.rel_path, entry.name });

            stack.append(.{
                .abs_path = child_abs,
                .rel_path = child_rel,
                .level = frame.level + 1,
            }) catch {
                allocator.free(child_abs);
                allocator.free(child_rel);
                return error.OutOfMemory;
            };
        }

        allocator.free(frame.abs_path);
        allocator.free(frame.rel_path);
    }

    return try records.toOwnedSlice();
}

const PRIO_DARWIN_PROCESS = 4;
const PRIO_DARWIN_BG = 0x1000;

pub fn setBackgroundPriority() !void {
    const bg: c_int = @intCast(PRIO_DARWIN_BG);
    const rc = c.setpriority(PRIO_DARWIN_PROCESS, 0, bg);
    if (rc != 0) return error.Unsupported;
}

fn dirGencountRecord(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    rel_path: []const u8,
) !types.GencountRecord {
    const st = try std.fs.cwd().statFile(abs_path);
    const mtime_u64: u64 = if (st.mtime < 0) 0 else @intCast(st.mtime);
    return .{
        .path = try allocator.dupe(u8, rel_path),
        .value = mtime_u64 ^ st.size,
    };
}
