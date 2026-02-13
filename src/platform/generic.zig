const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const darwin = @import("darwin.zig");
const linux = @import("linux.zig");

pub const DirEntryKind = enum(u8) {
    file,
    directory,
    symlink,
    other,
};

pub const DirEntry = struct {
    name: []const u8,
    kind: DirEntryKind,
    size: u64,
    device_id: u64,
};

const PlatformIterator = switch (builtin.os.tag) {
    .macos => darwin.DirIterator,
    else => linux.DirIterator,
};

pub const DirIterator = PlatformIterator;

pub const DirIteratorEntry = switch (builtin.os.tag) {
    .macos => darwin.DirEntry,
    else => linux.DirEntry,
};

pub fn openDirIterator(allocator: std.mem.Allocator, path: []const u8) !DirIterator {
    return if (builtin.os.tag == .macos) try darwin.openDirIterator(allocator, path) else try linux.openDirIterator(allocator, path);
}

pub fn getVolumeInfo(path: []const u8) !types.VolumeInfo {
    return if (builtin.os.tag == .macos) try darwin.getVolumeInfo(path) else try linux.getVolumeInfo(path);
}

pub fn setBackgroundPriority() !void {
    if (builtin.os.tag == .macos) {
        try darwin.setBackgroundPriority();
    } else {
        try linux.setBackgroundPriority();
    }
}
