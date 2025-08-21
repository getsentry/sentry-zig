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
pub const deinitScopeManager = scopes.deinitScopeManager;

pub const panicHandler = @import("panic_handler.zig").panicHandler;
pub const stack_trace = @import("utils/stack_trace.zig");

pub fn init(allocator: Allocator, dsn: ?[]const u8, options: SentryOptions) !*SentryClient {
    try scopes.initScopeManager(allocator);
    const client = try allocator.create(SentryClient);
    client.* = try SentryClient.init(allocator, dsn, options);
    const global_scope = try scopes.getGlobalScope();
    global_scope.bindClient(client);
    return client;
}

/// Properly shutdown and cleanup the Sentry client and all associated resources
pub fn shutdown(allocator: Allocator, client: *SentryClient) void {
    client.deinit();
    allocator.destroy(client);
    scopes.deinitScopeManager();
}

pub fn captureEvent(event: Event) !?EventId {
    return try scopes.captureEvent(event);
}

pub fn captureMessage(message: []const u8, level: Level) !?EventId {
    const event = Event.fromMessage(message, level);
    return captureEvent(event);
}

pub fn captureError(err: anyerror) !?EventId {
    const allocator = try scopes.getAllocator();
    var event = Event.fromError(allocator, err);
    errdefer event.deinit();
    return captureEvent(event);
}

test "compile and test everything" {
    _ = @import("panic_handler.zig");
    std.testing.refAllDeclsRecursive(@This());
}
