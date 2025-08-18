const std = @import("std");
const BreadcrumbType = @import("BreadcrumbType.zig").BreadcrumbType;
const Level = @import("Level.zig").Level;
const Allocator = std.mem.Allocator;

/// Breadcrumb for tracing user actions and events
pub const Breadcrumb = struct {
    message: []const u8,
    type: BreadcrumbType,
    level: Level,
    category: ?[]const u8 = null,
    timestamp: i64,
    data: ?std.StringHashMap([]const u8) = null,

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
