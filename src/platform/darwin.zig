const std = @import("std");
const types = @import("../types.zig");
const builtin = @import("builtin");

pub const DirEntry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    size: u64,
    device_id: u64,
};

pub const DirIterator = struct {
    iterable: std.fs.IterableDir,
    iterator: std.fs.IterableDir.Iterator,
    allocator: std.mem.Allocator,

    pub fn next(self: *DirIterator) !?DirEntry {
        const entry = try self.iterator.next() orelse return null;

        var size: u64 = 0;
        const stat = self.iterable.dir.statFile(entry.name) catch null;
        if (stat) |entry_stat| {
            size = switch (entry_stat.kind) {
                .file, .character_device, .block_device, .named_pipe, .unix_domain_socket, .symbolic_link => entry_stat.size,
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
        self.iterable.close();
    }
};

pub fn openDirIterator(allocator: std.mem.Allocator, path: []const u8) !DirIterator {
    const iterable = try std.fs.cwd().openIterableDir(path, .{});
    return .{
        .iterable = iterable,
        .iterator = iterable.iterate(),
        .allocator = allocator,
    };
}

pub fn getVolumeInfo(path: []const u8) !types.VolumeInfo {
    var fs = std.mem.zeroes(std.c.statfs_t);
    if (std.c.statfs(path.ptr, &fs) != 0) {
        return error.StatFSFailed;
    }

    const total = fs.blocks * fs.bsize;
    const free = fs.bavail * fs.bsize;
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

pub fn getRecursiveGencount(path: []const u8) !?u64 {
    _ = path;
    const fs = getVolumeInfo(path) catch return null;
    if (fs.fs_type != .apfs and fs.fs_type != .hfsplus) return null;
    return null;
}

pub fn getSubtreeGencounts(
    allocator: std.mem.Allocator,
    path: []const u8,
    depth: usize,
) !?[]types.GencountRecord {
    _ = allocator;
    _ = path;
    _ = depth;
    return null;
}

const PRIO_DARWIN_PROCESS = 4;
const PRIO_DARWIN_BG = 0x1000;

pub fn setBackgroundPriority() !void {
    _ = builtin;
    const bg = @intCast(c_int, PRIO_DARWIN_BG);
    const rc = std.c.setpriority(PRIO_DARWIN_PROCESS, 0, bg);
    if (rc != 0) return error.Unsupported;
}
