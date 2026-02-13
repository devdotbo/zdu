const std = @import("std");

pub const FsType = enum(u8) {
    apfs = 1,
    hfsplus = 2,
    ext4 = 3,
    xfs = 4,
    btrfs = 5,
    other = 255,
};

pub const SessionState = enum(u8) {
    idle = 0,
    scanning = 1,
    completing = 2,
    done = 3,
    err = 4,
    cleaned = 5,
};

pub const VolumeInfo = struct {
    mount_point: []const u8,
    fs_type: FsType,
    total_bytes: u64,
    used_bytes: u64,
    free_bytes: u64,

    pub fn filesystemName(self: VolumeInfo) []const u8 {
        return switch (self.fs_type) {
            .apfs => "apfs",
            .hfsplus => "hfs+",
            .ext4 => "ext4",
            .xfs => "xfs",
            .btrfs => "btrfs",
            .other => self.mount_point,
        };
    }
};

pub const DirectoryEntry = struct {
    path: []const u8,
    size_bytes: u64,
    file_count: u32,
    dir_count: u32,
    depth: u8,
    children: []DirectoryEntry,

    pub fn percentOf(self: DirectoryEntry, total: u64) f64 {
        if (total == 0) return 0.0;
        return (100.0 * @as(f64, @floatFromInt(self.size_bytes))) / @as(f64, @floatFromInt(total));
    }
};

pub const ScanResult = struct {
    path: []const u8,
    timestamp: i64,
    duration_ms: u64,
    volume_info: VolumeInfo,
    root_entry: *DirectoryEntry,
    entry_count: u64,
    cache_timestamp: ?i64 = null,
};

pub const ScanProgress = struct {
    files_scanned: u64,
    dirs_scanned: u64,
    bytes_scanned: u64,
    errors_count: u32,
    estimated_remaining_seconds: ?u32,
    percent_complete: ?f32,
};

pub const CacheHeader = extern struct {
    magic: [4]u8,
    version: u32,
    timestamp: i64,
    scan_duration_ms: u64,
    entry_count: u64,
};

comptime {
    std.debug.assert(@sizeOf(CacheHeader) == 32);
}

pub const Config = struct {
    base_dir: []const u8,
    cache_dir: []const u8,
    log_dir: []const u8,
    max_cache_bytes: u64,
    default_depth: u8,
    default_top: u16,
    max_log_age_days: u16,

    pub fn defaults() Config {
        return .{
            .base_dir = "~/.zigdu",
            .cache_dir = "~/.zigdu/cache",
            .log_dir = "~/.zigdu/logs",
            .max_cache_bytes = 1024 * 1024 * 1024,
            .default_depth = 3,
            .default_top = 20,
            .max_log_age_days = 30,
        };
    }

    pub fn validate(config: Config) Config {
        var out = config;

        if (out.max_cache_bytes < 10 * 1024 * 1024) {
            out.max_cache_bytes = 10 * 1024 * 1024;
        }

        if (out.default_depth == 0) {
            out.default_depth = 1;
        }
        if (out.default_depth > 255) {
            out.default_depth = 255;
        }

        if (out.default_top == 0) {
            out.default_top = 1;
        }
        if (out.default_top > 65535) {
            out.default_top = 65535;
        }

        if (out.max_log_age_days == 0) {
            out.max_log_age_days = 1;
        }

        return out;
    }
};
