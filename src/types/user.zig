const std = @import("std");
const Allocator = std.mem.Allocator;

/// User information for Sentry events
pub const User = struct {
    id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    ip_address: ?[]const u8 = null,

    pub fn deinit(self: *User, allocator: Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.username) |username| allocator.free(username);
        if (self.email) |email| allocator.free(email);
        if (self.name) |name| allocator.free(name);
        if (self.ip_address) |ip| allocator.free(ip);
    }
};
