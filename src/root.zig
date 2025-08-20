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
pub const StackTrace = types.StackTrace;
pub const Exception = types.Exception;
pub const Frame = types.Frame;

pub const SentryClient = @import("client.zig").SentryClient;

const scopes = @import("scope.zig");
pub const ScopeType = scopes.ScopeType;
pub const addBreadcrumb = scopes.addBreadcrumb;

const panic_handler_mod = @import("panic_handler.zig");
pub const panicHandler = panic_handler_mod.panicHandler;
pub const createSentryEvent = panic_handler_mod.createSentryEvent;

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

pub fn captureMessage(message: []const u8, level: Level) ?EventId {
    const event = Event.fromMessage(message, level);
    return captureEvent(event);
}

test "run all tests" {
    _ = @import("scope.zig");
    _ = @import("transport.zig");
    _ = @import("client.zig");
}

test "compile check everything" {
    std.testing.refAllDeclsRecursive(@This());
}
