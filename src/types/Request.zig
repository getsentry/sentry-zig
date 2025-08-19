const std = @import("std");
const Allocator = std.mem.Allocator;
const json_utils = @import("../utils/json_utils.zig");

/// Request interface
pub const Request = struct {
    url: ?[]const u8 = null,
    method: ?[]const u8 = null,
    data: ?[]const u8 = null,
    query_string: ?[]const u8 = null,
    cookies: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    env: ?std.StringHashMap([]const u8) = null,

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Request, jw: anytype) !void {
        try jw.beginObject();

        // Auto-serialize all non-HashMap fields
        if (self.url) |v| {
            try jw.objectField("url");
            try jw.write(v);
        }
        if (self.method) |v| {
            try jw.objectField("method");
            try jw.write(v);
        }
        if (self.data) |v| {
            try jw.objectField("data");
            try jw.write(v);
        }
        if (self.query_string) |v| {
            try jw.objectField("query_string");
            try jw.write(v);
        }
        if (self.cookies) |v| {
            try jw.objectField("cookies");
            try jw.write(v);
        }

        // Custom HashMap serialization
        if (self.headers) |headers| {
            try jw.objectField("headers");
            try json_utils.serializeStringHashMap(headers, jw);
        }
        if (self.env) |env| {
            try jw.objectField("env");
            try json_utils.serializeStringHashMap(env, jw);
        }

        try jw.endObject();
    }

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
