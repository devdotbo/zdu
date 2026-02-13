const std = @import("std");

const Allocator = std.mem.Allocator;

fn isSlash(c: u8) bool {
    return c == '/';
}

pub fn canonicalize(allocator: Allocator, input_path: []const u8) ![]const u8 {
    if (input_path.len == 0) return error.InvalidPath;
    const expanded = try expandHome(allocator, input_path);
    defer allocator.free(expanded);

    const resolved = if (std.fs.path.isAbsolute(expanded))
        try std.fs.cwd().realpathAlloc(allocator, expanded)
    else blk: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        const joined = try std.fs.path.join(allocator, &.{ cwd, expanded });
        defer allocator.free(joined);

        break :blk try std.fs.cwd().realpathAlloc(allocator, joined);
    };

    if (!std.unicode.utf8ValidateSlice(resolved)) {
        allocator.free(resolved);
        return error.InvalidUtf8;
    }

    if (resolved.len <= 1) {
        return resolved;
    }

    var trim_len = resolved.len;
    while (trim_len > 1 and isSlash(resolved[trim_len - 1])) {
        trim_len -= 1;
    }

    if (trim_len == resolved.len) {
        return resolved;
    }

    const trimmed = try allocator.dupe(u8, resolved[0..trim_len]);
    allocator.free(resolved);
    return trimmed;
}

pub fn expandHome(allocator: Allocator, input_path: []const u8) ![]const u8 {
    if (input_path.len == 0) return try allocator.dupe(u8, input_path);
    if (input_path[0] != '~') return try allocator.dupe(u8, input_path);
    if (input_path.len > 1 and input_path[1] != '/') return try allocator.dupe(u8, input_path);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return try allocator.dupe(u8, input_path);
    const home_trimmed = if (home.len > 0 and home[home.len - 1] == '/') home[0 .. home.len - 1] else home;
    if (input_path.len == 1) return home_trimmed;

    const tail = input_path[1..];
    return try std.fs.path.join(allocator, &.{ home_trimmed, tail });
}

pub fn hashPath(allocator: Allocator, path: []const u8) ![]const u8 {
    var hash: u64 = 0xcbf29ce484222325;
    for (path) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }

    var buf: [16]u8 = undefined;
    const len = try std.fmt.bufPrint(&buf, "{x:0>16}", .{hash});
    return try allocator.dupe(u8, len);
}
