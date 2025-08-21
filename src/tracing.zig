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

/// Simple span context - no complex thread-local stacks like before
threadlocal var current_span: ?*anyopaque = null;

fn shouldSample(client: *const SentryClient, ctx: *const TransactionContext) bool {
    // 1. Use parent sampling decision if available
    if (ctx.sampled) |sampled| {
        std.log.debug("Using parent sampling decision: {?}", .{sampled});
        return sampled;
    }

    // 2. Use sample_rate
    const rate = client.options.sample_rate orelse return false;

    if (rate <= 0.0) {
        std.log.debug("Dropping transaction: sample_rate is {d}", .{rate});
        return false;
    }

    if (rate >= 1.0) {
        return true;
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

/// Start a transaction (following Go's StartTransaction pattern)
pub fn startTransaction(allocator: Allocator, name: []const u8, op: []const u8) !?*Transaction {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction", .{});
        return null;
    };

    const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();
    const ctx = TransactionContext.fromPropagationContext(name, op, propagation_context);

    if (!shouldSample(client, &ctx)) {
        return null;
    }

    const transaction = try Transaction.init(allocator, ctx);
    transaction.sampled = .True;

    // Set transaction on current scope (like Go's hub.Scope().SetSpan(&span))
    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    // Store current span reference (simplified from complex stacks)
    current_span = transaction;

    return transaction;
}

/// Continue a transaction from headers (like Go's ContinueFromHeaders)
pub fn continueFromHeaders(allocator: Allocator, name: []const u8, op: []const u8, sentry_trace: []const u8) !?*Transaction {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction from header", .{});
        return null;
    };

    var ctx = TransactionContext{
        .name = name,
        .op = op,
    };

    try ctx.updateFromHeader(sentry_trace);

    // For transactions from headers, we always create the transaction to continue the trace,
    // but we respect the parent's sampling decision from the header
    const should_sample = if (ctx.sampled) |sampled| sampled else shouldSample(client, &ctx);

    const transaction = try Transaction.init(allocator, ctx);
    transaction.sampled = if (should_sample) .True else .False;

    // Set transaction on current scope
    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    current_span = transaction;

    return transaction;
}

/// Finish the current transaction
pub fn finishTransaction(transaction: *Transaction) void {
    transaction.finish();

    // Clear transaction from scope
    if (scope.getCurrentScope() catch null) |current_scope| {
        if (current_scope.getSpan() == @as(?*anyopaque, transaction)) {
            current_scope.setSpan(null);
        }
    }

    // Send to Sentry if sampled
    if (transaction.sampled.toBool()) {
        sendTransactionToSentry(transaction) catch |err| {
            std.log.err("Failed to send transaction to Sentry: {}", .{err});
        };
    }

    current_span = null;
}

fn sendTransactionToSentry(transaction: *Transaction) !void {
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

/// Start a child span from the current transaction
pub fn startSpan(_: Allocator, op: []const u8, description: ?[]const u8) !?*Span {
    // In Go SDK, spans inherit from parent or current transaction
    const active_transaction: ?*Transaction = @ptrCast(@alignCast(current_span));
    const transaction = active_transaction orelse {
        std.log.debug("No active transaction, cannot start span", .{});
        return null;
    };

    if (transaction.sampled != .True) {
        std.log.debug("Transaction not sampled, skipping span creation", .{});
        return null;
    }

    const span = try transaction.startSpan(op, description);
    return span;
}

/// Get current span (transaction or span)
pub fn getCurrentSpan() ?*anyopaque {
    return current_span;
}

/// Get sentry-trace header value
pub fn getSentryTrace(allocator: Allocator) !?[]u8 {
    if (current_span) |span_ptr| {
        const transaction: *Transaction = @ptrCast(@alignCast(span_ptr));
        return try transaction.toSentryTrace(allocator);
    } else {
        const propagation_context = scope.getPropagationContext() catch return null;
        const trace_hex = propagation_context.trace_id.toHexFixed();
        const span_hex = propagation_context.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    }
}

/// Get current active transaction (Go SDK equivalent)
pub fn getCurrentTransaction() ?*Transaction {
    return @ptrCast(@alignCast(current_span));
}
