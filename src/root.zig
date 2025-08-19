const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const types = @import("Types.zig");
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

pub fn init(allocator: Allocator, dsn: Dsn, options: SentryOptions) !SentryClient {
    scopes.initScopeManager(allocator);
    const client = try SentryClient.init(allocator, dsn, options);
    scopes.getGlobalScope().bindClient(client);
    return client;
}

pub fn captureEvent(event: Event) ?EventId {
    const client = scopes.getClient() orelse return null;
    // TODO: apply scope data to event
    return client.captureEvent(event);
}

pub fn captureError(err: anyerror) ?EventId {
    const allocator = scopes.getAllocator();
    const event = Event.fromError(allocator, err);
    defer event.deinit(allocator);
    return captureEvent(event);
}

pub fn captureMessage(
    message: []const u8,
    level: Level,
) ?EventId {
    const allocator = scopes.getAllocator();
    const event = Event.fromMessage(allocator, message, level);
    defer event.deinit(allocator);
    return captureEvent(event);
}

pub const ConfigureScopeOptions = struct {
    scope_type: ?ScopeType,
};

pub const ConfigureScopeCallback = fn (*scopes.Scope) void;

pub fn configureScope(options: ConfigureScopeOptions, callback: ConfigureScopeCallback, context: ?*anyopaque) void {
    const scope_type = options.scope_type orelse ScopeType.isolation;
    const scope = try scopes.getScope(scope_type);
    callback(scope, context);
}
