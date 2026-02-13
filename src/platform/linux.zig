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
    var fs = std.mem.zeroes(std.c.statvfs_t);
    if (std.c.statvfs(path.ptr, &fs) != 0) {
        return error.StatFSFailed;
    }

    const total = fs.blocks * fs.f_bsize;
    const free = fs.bavail * fs.f_bsize;
    const used = if (total >= free) total - free else 0;

    return .{
        .mount_point = "/",
        .fs_type = .other,
        .total_bytes = @intCast(total),
        .used_bytes = @intCast(used),
        .free_bytes = @intCast(free),
    };
}

pub fn setBackgroundPriority() !void {
    _ = std.c.nice(19);
    _ = builtin;
}
