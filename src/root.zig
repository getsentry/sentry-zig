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

pub const SentryClient = @import("client.zig").SentryClient;

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

pub fn captureEvent(event: Event) !?EventId {
    return try scopes.captureEvent(event);
}

pub const startTransaction = tracing.startTransaction;

pub const startTransactionFromHeader = tracing.startTransactionFromHeader;

pub const finishTransaction = tracing.finishTransaction;

pub const startSpan = tracing.startSpan;

pub const finishSpan = tracing.finishSpan;

pub const withTransaction = tracing.withTransaction;

pub const withSpan = tracing.withSpan;

pub const setTrace = tracing.setTrace;

pub const getSentryTrace = tracing.getSentryTrace;

pub const getActiveTransaction = tracing.getActiveTransaction;

pub const getActiveSpan = tracing.getActiveSpan;


test "compile check everything" {
    std.testing.refAllDeclsRecursive(@This());
}
