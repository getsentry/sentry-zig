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
pub const Mechanism = types.Mechanism;
pub const Frame = types.Frame;

pub const SentryClient = @import("client.zig").SentryClient;

const scopes = @import("scope.zig");
pub const ScopeType = scopes.ScopeType;
pub const addBreadcrumb = scopes.addBreadcrumb;

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

pub fn captureEvent(event: Event) !?EventId {
    return try scopes.captureEvent(event);
}

pub fn captureMessage(message: []const u8, level: Level) !?EventId {
    const event = Event.fromMessage(message, level);
    return captureEvent(event);
}

/// Create an Event from an error with automatic stack trace capture
fn eventFromError(allocator: Allocator, err: anyerror) Event {
    // Try to collect error trace if available
    const stacktrace = stack_trace.collectErrorTrace(allocator, @errorReturnTrace()) catch null;

    // Get error name
    const error_name = @errorName(err);

    // Create exception
    const exception = Exception{
        .type = error_name,
        .value = error_name,
        .module = null,
        .thread_id = @as(u64, @intCast(std.Thread.getCurrentId())),
        .stacktrace = stacktrace,
        .mechanism = Mechanism{
            .type = "error",
            .handled = true,
        },
    };

    return Event{
        .event_id = EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = "error_handler",
    };
}

pub fn captureError(err: anyerror) !?EventId {
    const allocator = try scopes.getAllocator();
    var event = eventFromError(allocator, err);
    errdefer event.deinit();
    return captureEvent(event);
}

test "compile and test everything" {
    _ = @import("panic_handler.zig");
    std.testing.refAllDeclsRecursive(@This());
}
