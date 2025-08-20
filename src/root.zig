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

pub fn init(allocator: Allocator, dsn: ?[]const u8, options: SentryOptions) !*SentryClient {
    try scopes.initScopeManager(allocator);
    const client = try allocator.create(SentryClient);
    client.* = try SentryClient.init(allocator, dsn, options);
    const global_scope = try scopes.getGlobalScope();
    global_scope.bindClient(client);
    return client;
}

pub fn captureEvent(event: Event) ?EventId {
    const client = scopes.getClient() orelse return null;
    const event_id_bytes = client.captureEvent(event) catch return null;
    if (event_id_bytes) |bytes| {
        return EventId{ .value = bytes };
    }
    return null;
}

test "run all tests" {
    _ = @import("scope.zig");
    _ = @import("transport.zig");
    _ = @import("client.zig");
    _ = @import("panic_handler.zig");
}

test "compile check everything" {
    std.testing.refAllDeclsRecursive(@This());
}
