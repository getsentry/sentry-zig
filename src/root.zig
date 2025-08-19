const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const types = @import("types");
pub const Event = types.Event;
pub const EventId = types.EventId;
pub const SentryOptions = types.SentryOptions;
pub const Breadcrumb = types.Breadcrumb;
pub const Dsn = types.Dsn;
pub const Level = types.Level;

pub const SentryClient = @import("client.zig").SentryClient;

const scopes = @import("scope.zig");
pub const ScopeType = scopes.ScopeType;
pub const addBreadcrumb = scopes.addBreadcrumb;

pub fn init(allocator: Allocator, dsn: ?[]const u8, options: SentryOptions) !SentryClient {
    try scopes.initScopeManager(allocator);
    var client = try SentryClient.init(allocator, dsn, options);
    std.log.debug("hello", .{});
    const global_scope = try scopes.getGlobalScope();
    global_scope.bindClient(&client);
    std.log.debug("hello", .{});
    return client;
}

pub fn captureEvent(event: Event) ?EventId {
    std.log.debug("capture event", .{});
    const client = scopes.getClient() orelse return null;
    const event_id_bytes = client.captureEvent(event) catch return null;
    if (event_id_bytes) |bytes| {
        return EventId{ .value = bytes };
    }
    return null;
}

pub fn captureError(err: anyerror) ?EventId {
    const global_scope = scopes.getGlobalScope() catch return null;
    const event = Event.fromError(global_scope.allocator, err);
    defer event.deinit(global_scope.allocator);
    return captureEvent(event);
}

pub fn captureMessage(
    message: []const u8,
    level: Level,
) ?EventId {
    const global_scope = scopes.getGlobalScope() catch return null;
    const event = Event.fromMessage(global_scope.allocator, message, level);
    defer event.deinit(global_scope.allocator);
    return captureEvent(event);
}

test "test transport" {
    _ = @import("transport.zig");
}
