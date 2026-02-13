const std = @import("std");
const types = @import("../types.zig");

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
    _ = path;

    return .{
        .mount_point = "/",
        .fs_type = .other,
        .fs_identifier = "other",
        .total_bytes = 0,
        .used_bytes = 0,
        .free_bytes = 0,
    };
}

pub fn setBackgroundPriority() !void {
    var lowered = false;

    const nice_result = std.os.linux.syscall1(.nice, @as(usize, @bitCast(@as(isize, 19))));
    if (std.posix.errno(nice_result) == .SUCCESS) lowered = true;

    const ioprio_result = std.os.linux.syscall3(
        .ioprio_set,
        1,
        0,
        (3 << 13) | 0,
    );
    if (std.posix.errno(ioprio_result) == .SUCCESS) lowered = true;

    if (!lowered) {
        return error.Unsupported;
    }
}
