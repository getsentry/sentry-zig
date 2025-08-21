const std = @import("std");
const types = @import("types");

const Event = types.Event;
const EventId = types.EventId;
const User = types.User;
const Breadcrumb = types.Breadcrumb;
const BreadcrumbType = types.BreadcrumbType;
const Level = types.Level;
const Breadcrumbs = types.Breadcrumbs;
const Message = types.Message;

/// Helper function to create a full test event with all fields populated
pub fn createFullTestEvent(allocator: std.mem.Allocator) !Event {
    var tags = std.StringHashMap([]const u8).init(allocator);
    try tags.put(try allocator.dupe(u8, "environment"), try allocator.dupe(u8, "test"));
    try tags.put(try allocator.dupe(u8, "version"), try allocator.dupe(u8, "1.0.0"));

    var modules = std.StringHashMap([]const u8).init(allocator);
    try modules.put(try allocator.dupe(u8, "mymodule"), try allocator.dupe(u8, "1.0.0"));

    var fingerprint = try allocator.alloc([]const u8, 2);
    fingerprint[0] = try allocator.dupe(u8, "custom");
    fingerprint[1] = try allocator.dupe(u8, "fingerprint");

    const user = try User.init(
        allocator,
        "123",
        "testuser",
        "test@example.com",
        "Test User",
        "192.168.1.1",
    );
    defer user.deinit();

    var breadcrumb_data = std.StringHashMap([]const u8).init(allocator);
    try breadcrumb_data.put(try allocator.dupe(u8, "url"), try allocator.dupe(u8, "/api/test"));
    try breadcrumb_data.put(try allocator.dupe(u8, "method"), try allocator.dupe(u8, "GET"));

    const breadcrumb = Breadcrumb{
        .message = try allocator.dupe(u8, "HTTP Request"),
        .type = BreadcrumbType.http,
        .level = Level.info,
        .category = try allocator.dupe(u8, "http"),
        .timestamp = std.time.timestamp(),
        .data = breadcrumb_data,
    };

    var breadcrumbs_values = try allocator.alloc(Breadcrumb, 1);
    breadcrumbs_values[0] = breadcrumb;

    const breadcrumbs = Breadcrumbs{
        .values = breadcrumbs_values,
    };

    const message = Message{
        .message = try allocator.dupe(u8, "Test error message"),
        .params = null,
        .formatted = try allocator.dupe(u8, "Test error message"),
    };

    return Event.init(
        allocator,
        EventId.new(),
        @as(f64, @floatFromInt(std.time.timestamp())),
        "native", // Use default literal to avoid memory allocation
        Level.@"error",
        "test-logger",
        "test-transaction",
        "test-server",
        "1.0.0",
        "1",
        tags,
        "test",
        modules,
        fingerprint,
        null,
        null,
        message,
        null,
        null,
        breadcrumbs,
        user,
        null,
        null,
        null,
        null,
        null,
    );
}
