const std = @import("std");
const Allocator = std.mem.Allocator;

/// Request interface
pub const Request = struct {
    url: ?[]const u8 = null,
    method: ?[]const u8 = null,
    data: ?[]const u8 = null,
    query_string: ?[]const u8 = null,
    cookies: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    env: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *Request, allocator: Allocator) void {
        if (self.url) |url| allocator.free(url);
        if (self.method) |method| allocator.free(method);
        if (self.data) |data| allocator.free(data);
        if (self.query_string) |query_string| allocator.free(query_string);
        if (self.cookies) |cookies| allocator.free(cookies);

        if (self.headers) |*headers| {
            var iterator = headers.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        if (self.env) |*env| {
            var iterator = env.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            env.deinit();
        }
    }
};
