const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// User information for Sentry events
pub const User = struct {
    allocator: ?Allocator = null,

    id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    ip_address: ?[]const u8 = null,

    pub fn init(
        allocator: Allocator,
        id: ?[]const u8,
        username: ?[]const u8,
        email: ?[]const u8,
        name: ?[]const u8,
        ip_address: ?[]const u8,
    ) !@This() {
        const id_copy = if (id) |id_capture| try allocator.dupe(u8, id_capture) else null;
        const username_copy = if (username) |username_capture| try allocator.dupe(u8, username_capture) else null;
        const email_copy = if (email) |email_capture| try allocator.dupe(u8, email_capture) else null;
        const name_copy = if (name) |name_capture| try allocator.dupe(u8, name_capture) else null;
        const ip_address_copy = if (ip_address) |ip_address_capture| try allocator.dupe(u8, ip_address_capture) else null;

        return .{
            .allocator = allocator,

            .id = id_copy,
            .username = username_copy,
            .email = email_copy,
            .name = name_copy,
            .ip_address = ip_address_copy,
        };
    }

    pub fn deinit(self: *const @This()) void {
        if (self.allocator) |allocator| if (self.id) |id| allocator.free(id);
        if (self.allocator) |allocator| if (self.username) |username| allocator.free(username);
        if (self.allocator) |allocator| if (self.email) |email| allocator.free(email);
        if (self.allocator) |allocator| if (self.name) |name| allocator.free(name);
        if (self.allocator) |allocator| if (self.ip_address) |ip| allocator.free(ip);
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        if (self.id) |id| {
            try jw.objectField("id");
            try jw.write(id);
        }
        if (self.username) |username| {
            try jw.objectField("username");
            try jw.write(username);
        }
        if (self.email) |email| {
            try jw.objectField("email");
            try jw.write(email);
        }
        if (self.name) |name| {
            try jw.objectField("name");
            try jw.write(name);
        }
        if (self.ip_address) |ip_address| {
            try jw.objectField("ip_address");
            try jw.write(ip_address);
        }

        try jw.endObject();
    }

    /// Create a deep copy of the user
    pub fn clone(self: User, allocator: Allocator) !User {
        return User{
            .allocator = allocator,
            .id = if (self.id) |id| try allocator.dupe(u8, id) else null,
            .username = if (self.username) |username| try allocator.dupe(u8, username) else null,
            .email = if (self.email) |email| try allocator.dupe(u8, email) else null,
            .name = if (self.name) |name| try allocator.dupe(u8, name) else null,
            .ip_address = if (self.ip_address) |ip| try allocator.dupe(u8, ip) else null,
        };
    }
};

test "User - clone functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create original user
    var original = User{
        .id = try allocator.dupe(u8, "123"),
        .username = try allocator.dupe(u8, "testuser"),
        .email = try allocator.dupe(u8, "test@example.com"),
        .name = try allocator.dupe(u8, "Test User"),
        .ip_address = try allocator.dupe(u8, "192.168.1.1"),
    };
    defer original.deinit(allocator);

    // Clone the user
    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    // Verify all fields were cloned
    try testing.expectEqualStrings("123", cloned.id.?);
    try testing.expectEqualStrings("testuser", cloned.username.?);
    try testing.expectEqualStrings("test@example.com", cloned.email.?);
    try testing.expectEqualStrings("Test User", cloned.name.?);
    try testing.expectEqualStrings("192.168.1.1", cloned.ip_address.?);

    // Verify they are different memory locations
    try testing.expect(original.id.?.ptr != cloned.id.?.ptr);
    try testing.expect(original.username.?.ptr != cloned.username.?.ptr);
}

test "User - clone with null fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create user with some null fields
    var original = User{
        .id = try allocator.dupe(u8, "456"),
        .username = null,
        .email = try allocator.dupe(u8, "partial@example.com"),
        .name = null,
        .ip_address = null,
    };
    defer original.deinit(allocator);

    // Clone the user
    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    // Verify fields were cloned correctly
    try testing.expectEqualStrings("456", cloned.id.?);
    try testing.expect(cloned.username == null);
    try testing.expectEqualStrings("partial@example.com", cloned.email.?);
    try testing.expect(cloned.name == null);
    try testing.expect(cloned.ip_address == null);
}
