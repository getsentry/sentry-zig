const std = @import("std");

/// Request interface
pub const Request = struct {
    url: ?[]const u8 = null,
    method: ?[]const u8 = null,
    data: ?[]const u8 = null,
    query_string: ?[]const u8 = null,
    cookies: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    env: ?std.StringHashMap([]const u8) = null,
};
