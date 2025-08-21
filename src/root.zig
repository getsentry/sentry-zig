const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const types = @import("types");
const scopes = @import("scope.zig");
const tracing = @import("tracing.zig");
pub const Event = types.Event;
pub const EventId = types.EventId;
pub const SentryOptions = types.SentryOptions;
pub const Breadcrumb = types.Breadcrumb;
pub const Dsn = types.Dsn;
pub const Level = types.Level;
pub const Exception = types.Exception;
pub const TraceId = types.TraceId;
pub const SpanId = types.SpanId;
pub const PropagationContext = types.PropagationContext;
pub const Transaction = types.Transaction;
pub const TransactionContext = types.TransactionContext;
pub const TransactionStatus = types.TransactionStatus;
pub const Span = types.Span;
pub const StackTrace = types.StackTrace;
pub const Frame = types.Frame;

pub const SentryClient = @import("client.zig").SentryClient;

pub const ScopeType = scopes.ScopeType;
pub const addBreadcrumb = scopes.addBreadcrumb;

pub const panicHandler = @import("panic_handler.zig").panicHandler;

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

pub const startTransaction = tracing.startTransaction;
pub const continueFromHeaders = tracing.continueFromHeaders;
pub const finishTransaction = tracing.finishTransaction;
pub const startSpan = tracing.startSpan;
pub const getCurrentSpan = tracing.getCurrentSpan;
pub const getCurrentTransaction = tracing.getCurrentTransaction;
pub const getSentryTrace = tracing.getSentryTrace;

pub fn captureMessage(message: []const u8, level: Level) !?EventId {
    const event = Event.fromMessage(message, level);
    return captureEvent(event);
}

test "compile and test everything" {
    _ = @import("panic_handler.zig");
    std.testing.refAllDeclsRecursive(@This());
}
