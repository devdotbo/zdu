const std = @import("std");
const types = @import("../types.zig");

const c = @cImport({
    @cInclude("sys/resource.h");
    @cInclude("linux/ioprio.h");
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

pub fn getVolumeInfo(allocator: std.mem.Allocator, path: []const u8) !types.VolumeInfo {
    _ = allocator;
    var fs = std.mem.zeroes(std.c.statvfs_t);
    const path_buf = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_buf);
    if (std.c.statvfs(path_buf, &fs) != 0) {
        return error.StatFSFailed;
    }

    const total = fs.blocks * fs.f_bsize;
    const free = fs.bavail * fs.f_bsize;
    const used = if (total >= free) total - free else 0;

    return .{
        .mount_point = "/",
        .fs_type = .other,
        .fs_identifier = "other",
        .total_bytes = @intCast(total),
        .used_bytes = @intCast(used),
        .free_bytes = @intCast(free),
    };
}

pub fn setBackgroundPriority() !void {
    _ = std.c.nice(19);

    const rc = c.ioprio_set(c.IOPRIO_WHO_PROCESS, 0, (c.IOPRIO_CLASS_IDLE << 13) | 0);
    if (rc != 0) {
        return error.Unsupported;
    }
}
