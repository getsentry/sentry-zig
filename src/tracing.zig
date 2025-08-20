const std = @import("std");
const types = @import("types");
const scope = @import("scope.zig");
const SentryClient = @import("client.zig").SentryClient;

const TraceId = types.TraceId;
const SpanId = types.SpanId;
const PropagationContext = types.PropagationContext;
const Transaction = types.Transaction;
const TransactionContext = types.TransactionContext;
const TransactionStatus = types.TransactionStatus;
const Span = types.Span;
const Allocator = std.mem.Allocator;

const SentryTraceHeader = "sentry-trace";
const SentryBaggageHeader = "baggage";

pub const SpanOrigin = enum {
    manual,
    auto_http,

    pub fn toString(self: SpanOrigin) []const u8 {
        return switch (self) {
            .manual => "manual",
            .auto_http => "auto.http",
        };
    }
};

/// Sampling context passed to tracesSampler callback
pub const SamplingContext = struct {
    transaction_context: ?*const TransactionContext = null,
    parent_sampled: ?bool = null,
    parent_sample_rate: ?f64 = null,
    name: ?[]const u8 = null,
};

const Sampled = Transaction.Sampled;

threadlocal var active_transaction_stack: ?std.ArrayList(*Transaction) = null;
threadlocal var active_span_stack: ?std.ArrayList(*Span) = null;

pub fn initTracingTLS(allocator: Allocator) !void {
    if (active_transaction_stack == null) {
        active_transaction_stack = std.ArrayList(*Transaction).init(allocator);
    }
    if (active_span_stack == null) {
        active_span_stack = std.ArrayList(*Span).init(allocator);
    }
}

pub fn deinitTracingTLS() void {
    if (active_transaction_stack) |*stack| {
        stack.deinit();
        active_transaction_stack = null;
    }
    if (active_span_stack) |*stack| {
        stack.deinit();
        active_span_stack = null;
    }
}

pub fn getActiveTransaction() ?*Transaction {
    if (active_transaction_stack) |*stack| {
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }
    }
    return null;
}

pub fn getActiveSpan() ?*Span {
    if (active_span_stack) |*stack| {
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }
    }
    return null;
}

fn shouldSample(client: *const SentryClient, ctx: *const TransactionContext) bool {
    // 1. Use parent sampling decision if available
    if (ctx.sampled) |sampled| {
        std.log.debug("Using parent sampling decision: {}", .{sampled});
        return sampled;
    }

    // 2. Use traces_sample_rate
    const rate = client.options.traces_sample_rate orelse return .{ .should_sample = false, .sample_rate = 0.0 };

    if (rate <= 0.0) {
        std.log.debug("Dropping transaction: traces_sample_rate is {d}", .{rate});
        return .{ .should_sample = false, .sample_rate = rate };
    }

    if (rate >= 1.0) {
        return .{ .should_sample = true, .sample_rate = rate };
    }

    return generateSampleDecision(rate);
}

fn generateSampleDecision(sample_rate: f64) bool {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
    const random_value = prng.random().float(f64);

    if (random_value < sample_rate) {
        return true;
    }

    std.log.debug("Dropping transaction: random value {d} >= sample rate {d}", .{ random_value, sample_rate });
    return false;
}

pub fn startTransaction(allocator: Allocator, name: []const u8, op: []const u8) !?*Transaction {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction", .{});
        return null;
    };

    const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();
    const ctx = TransactionContext.fromPropagationContext(name, op, propagation_context);

    if (!shouldSample(client, &ctx, null)) {
        return null;
    }

    const transaction = try Transaction.init(allocator, ctx);
    transaction.sampled = .True;

    try initTracingTLS(allocator);

    if (active_transaction_stack) |*stack| {
        try stack.append(transaction);
    }

    // Set transaction on current scope
    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    return transaction;
}

pub fn startTransactionFromHeader(allocator: Allocator, name: []const u8, op: []const u8, sentry_trace: []const u8) !?*Transaction {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction from header", .{});
        return null;
    };

    var ctx = TransactionContext{
        .name = name,
        .op = op,
    };

    try ctx.updateFromHeader(sentry_trace);

    // TODO: Parse baggage header for parent sample rate
    if (!shouldSample(client, &ctx, null)) {
        return null;
    }

    const transaction = try Transaction.init(allocator, ctx);
    transaction.sampled = if (ctx.sampled) |sampled| (if (sampled) .True else .False) else .True;

    try initTracingTLS(allocator);

    if (active_transaction_stack) |*stack| {
        try stack.append(transaction);
    }

    // Set transaction on current scope
    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    return transaction;
}

pub fn finishTransaction() void {
    if (active_transaction_stack) |*stack| {
        if (stack.items.len > 0) {
            if (stack.pop()) |transaction| {
                transaction.finish();

                // Clear transaction from scope
                if (scope.getCurrentScope() catch null) |current_scope| {
                    if (current_scope.getSpan() == @as(?*anyopaque, transaction)) {
                        current_scope.setSpan(null);
                    }
                }

                sendTransactionToSentry(transaction) catch |err| {
                    std.log.err("Failed to send transaction to Sentry: {}", .{err});
                };
            }
        }
    }
}

fn sendTransactionToSentry(transaction: *Transaction) !void {
    if (!transaction.sampled.toBool()) {
        std.log.debug("Transaction not sampled, skipping send", .{});
        return;
    }

    std.log.debug("Sending transaction to Sentry: {s} (trace: {s})", .{
        transaction.name,
        &transaction.trace_id.toHexFixed(),
    });

    // Convert transaction to event and use scope.captureEvent for proper enrichment
    const event = transaction.toEvent();
    const event_id = try scope.captureEvent(event);

    if (event_id) |id| {
        std.log.debug("Transaction sent to Sentry with event ID: {s}", .{id.value});
    } else {
        std.log.debug("Transaction was not sent (filtered or no client)", .{});
    }
}

pub fn startSpan(allocator: Allocator, op: []const u8, description: ?[]const u8) !?*Span {
    const active_transaction = getActiveTransaction() orelse {
        std.log.debug("No active transaction, cannot start span", .{});
        return null;
    };

    if (active_transaction.sampled != .True) {
        std.log.debug("Transaction not sampled, skipping span creation", .{});
        return null;
    }

    try initTracingTLS(allocator);

    var span: *Span = undefined;

    if (getActiveSpan()) |active_span| {
        span = try active_span.startSpan(op, description);
    } else {
        span = try active_transaction.startSpan(op, description);
    }

    if (active_span_stack) |*stack| {
        try stack.append(span);
    }

    const span_context = PropagationContext{
        .trace_id = span.trace_id,
        .span_id = span.span_id,
        .parent_span_id = span.parent_span_id,
    };
    scope.setTrace(span_context.trace_id, span_context.span_id, span_context.parent_span_id) catch {};

    return span;
}

pub fn finishSpan() void {
    if (active_span_stack) |*stack| {
        if (stack.items.len > 0) {
            if (stack.pop()) |span| {
                span.finish();

                // Restore parent context
                if (stack.items.len > 0) {
                    const parent_span = stack.items[stack.items.len - 1];
                    const parent_context = PropagationContext{
                        .trace_id = parent_span.trace_id,
                        .span_id = parent_span.span_id,
                        .parent_span_id = parent_span.parent_span_id,
                    };
                    scope.setTrace(parent_context.trace_id, parent_context.span_id, parent_context.parent_span_id) catch {};
                } else if (getActiveTransaction()) |transaction| {
                    const tx_context = transaction.getPropagationContext();
                    scope.setTrace(tx_context.trace_id, tx_context.span_id, tx_context.parent_span_id) catch {};
                }
            }
        }
    }
}

pub fn withTransaction(allocator: Allocator, name: []const u8, op: []const u8, callback: anytype) !void {
    const transaction = try startTransaction(allocator, name, op) orelse return;
    defer {
        finishTransaction();
        transaction.deinit();
    }

    try callback(transaction);
}

pub fn withSpan(allocator: Allocator, op: []const u8, description: ?[]const u8, callback: anytype) !void {
    const span = try startSpan(allocator, op, description) orelse return;
    defer finishSpan();

    try callback(span);
}

/// Get sentry-trace header value according to spec: traceid-spanid-sampled
/// Format: 32 hex chars for traceId, 16 hex chars for spanId, optional sampled flag
pub fn getSentryTrace(allocator: Allocator) !?[]u8 {
    if (getActiveSpan()) |span| {
        const trace_hex = span.trace_id.toHexFixed();
        const span_hex = span.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    } else if (getActiveTransaction()) |transaction| {
        return try transaction.toSentryTrace(allocator);
    } else {
        const propagation_context = scope.getPropagationContext() catch return null;
        const trace_hex = propagation_context.trace_id.toHexFixed();
        const span_hex = propagation_context.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    }
}

/// Get current active span for Sentry.span static API
pub fn getCurrentSpan() ?*Span {
    return getActiveSpan() orelse if (getActiveTransaction()) |tx| @ptrCast(tx) else null;
}

test "transaction sampling" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    // Mock client with zero sample rate
    const options = types.SentryOptions{
        .traces_sample_rate = 0.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "test", "test");
    try std.testing.expect(transaction == null);

    deinitTracingTLS();
}

test "transaction creation with sampling" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .traces_sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "test_transaction", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction();
        transaction.?.deinit();
    }

    try std.testing.expectEqualStrings("test_transaction", transaction.?.name);
    try std.testing.expectEqualStrings("http.request", transaction.?.op);

    deinitTracingTLS();
}
