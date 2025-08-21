const std = @import("std");
const Allocator = std.mem.Allocator;

/// Deep clone a StringHashMap, duplicating all keys and values
pub fn cloneStringHashMap(allocator: Allocator, original: std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
    var cloned = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = cloned.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        cloned.deinit();
    }

    var iter = original.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        try cloned.put(key, value);
    }

    return cloned;
}
