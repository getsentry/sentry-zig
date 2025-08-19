const std = @import("std");
const BreadcrumbType = @import("BreadcrumbType.zig").BreadcrumbType;
const Level = @import("Level.zig").Level;
const Allocator = std.mem.Allocator;
const json_utils = @import("../utils/json_utils.zig");

/// Breadcrumb for tracing user actions and events
pub const Breadcrumb = struct {
    message: []const u8,
    type: BreadcrumbType,
    level: Level,
    category: ?[]const u8 = null,
    timestamp: i64,
    data: ?std.StringHashMap([]const u8) = null,

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Breadcrumb, jw: anytype) !void {
        try jw.beginObject();

        // Required fields
        try jw.objectField("message");
        try jw.write(self.message);
        try jw.objectField("type");
        try jw.write(@tagName(self.type));
        try jw.objectField("level");
        try jw.write(@tagName(self.level));
        try jw.objectField("timestamp");
        try jw.write(self.timestamp);

        // Optional simple fields
        if (self.category) |v| {
            try jw.objectField("category");
            try jw.write(v);
        }

        // HashMap field
        if (self.data) |data| {
            try jw.objectField("data");
            try json_utils.serializeStringHashMap(data, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Breadcrumb, allocator: Allocator) void {
        allocator.free(self.message);
        // Note: type and level are enums, they don't need to be freed
        if (self.category) |cat| allocator.free(cat);
        if (self.data) |*data| {
            var iterator = data.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            data.deinit();
        }
    }
};
