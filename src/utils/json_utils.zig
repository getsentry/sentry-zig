const std = @import("std");

/// Helper function to serialize StringHashMap to JSON
/// This handles the function pointer issue in Zig's JSON serializer
pub fn serializeStringHashMap(map: std.StringHashMap([]const u8), jw: anytype) !void {
    try jw.beginObject();
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try jw.objectField(entry.key_ptr.*);
        try jw.write(entry.value_ptr.*);
    }
    try jw.endObject();
}

/// Helper function to serialize nested StringHashMap (for contexts)
/// Handles StringHashMap(StringHashMap([]const u8))
pub fn serializeNestedStringHashMap(map: std.StringHashMap(std.StringHashMap([]const u8)), jw: anytype) !void {
    try jw.beginObject();
    var outer_iterator = map.iterator();
    while (outer_iterator.next()) |outer_entry| {
        try jw.objectField(outer_entry.key_ptr.*);
        try serializeStringHashMap(outer_entry.value_ptr.*, jw);
    }
    try jw.endObject();
}
