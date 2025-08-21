const std = @import("std");
const types = @import("types");
const scope = @import("scope.zig");
const SentryClient = @import("client.zig").SentryClient;

const TraceId = types.TraceId;
const SpanId = types.SpanId;
const PropagationContext = types.PropagationContext;
const Span = types.Span;
const Sampled = types.Sampled;
const SpanOrigin = types.SpanOrigin;
const TraceContext = types.TraceContext;
const Allocator = std.mem.Allocator;

const SentryTraceHeader = "sentry-trace";
const SentryBaggageHeader = "baggage";

/// Sampling context passed to tracesSampler callback
pub const SamplingContext = struct {
    trace_context: ?*const TraceContext = null,
    parent_sampled: ?bool = null,
    parent_sample_rate: ?f64 = null,
    name: ?[]const u8 = null,
};

threadlocal var current_span: ?*Span = null;

fn shouldSample(client: *const SentryClient, ctx: *const TraceContext) bool {
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

/// Start a transaction
/// A transaction is just a span with no parent
pub fn startTransaction(allocator: Allocator, name: []const u8, op: []const u8) !?*Span {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction", .{});
        return null;
    };

    const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();

    // Create transaction (root span with no parent)
    const transaction = try Span.init(allocator, op, null);

    try transaction.setTransactionName(name);
    transaction.trace_id = propagation_context.trace_id;
    transaction.span_id = propagation_context.span_id;
    transaction.parent_span_id = propagation_context.parent_span_id;

    // Apply sampling
    const ctx = TraceContext.fromPropagationContext(name, op, propagation_context);
    if (!shouldSample(client, &ctx)) {
        transaction.deinit();
        allocator.destroy(transaction);
        return null;
    }

    transaction.sampled = .True;

    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    scope.setTrace(transaction.trace_id, transaction.span_id, transaction.parent_span_id) catch {};

    current_span = transaction;

    return transaction;
}

/// Continue a transaction from headers
pub fn continueFromHeaders(allocator: Allocator, name: []const u8, op: []const u8, sentry_trace: []const u8) !?*Span {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction from header", .{});
        return null;
    };

    // Create transaction (root span with no parent)
    const transaction = try Span.init(allocator, op, null);
    try transaction.setTransactionName(name);

    // Update from sentry-trace header
    _ = transaction.updateFromSentryTrace(sentry_trace);

    // For transactions from headers, we always create the transaction to continue the trace,
    // but we respect the parent's sampling decision from the header
    var ctx = TraceContext{
        .name = name,
        .op = op,
    };
    try ctx.updateFromHeader(sentry_trace);

    const should_sample = if (ctx.sampled) |sampled| sampled else shouldSample(client, &ctx);
    transaction.sampled = if (should_sample) .True else .False;

    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    scope.setTrace(transaction.trace_id, transaction.span_id, transaction.parent_span_id) catch {};

    current_span = transaction;

    return transaction;
}

/// Finish the current transaction
pub fn finishTransaction(transaction: *Span) void {
    if (!transaction.isTransaction()) {
        std.log.warn("finishTransaction called on non-root span", .{});
        return;
    }

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

fn sendTransactionToSentry(transaction: *Span) !void {
    std.log.debug("Sending transaction to Sentry: {s} (trace: {s})", .{
        transaction.name orelse transaction.op,
        &transaction.trace_id.toHexFixed(),
    });

    // Convert transaction to event and use scope.captureEvent for proper enrichment
    const event = transaction.toEvent();
    const event_id = try scope.captureEvent(event);

    if (event_id) |id| {
        std.log.debug("Span sent to Sentry with event ID: {s}", .{id.value});
    } else {
        std.log.debug("Span was not sent (filtered or no client)", .{});
    }
}

/// Start a child span from the current transaction
pub fn startSpan(_: Allocator, op: []const u8, description: ?[]const u8) !?*Span {
    // Spans inherit from parent or current transaction
    const parent_span = current_span orelse {
        std.log.debug("No active span, cannot start child span", .{});
        return null;
    };

    if (parent_span.sampled != .True) {
        std.log.debug("Parent span not sampled, skipping span creation", .{});
        return null;
    }

    const span = try parent_span.startChild(op);
    if (description) |desc| {
        try span.setDescription(desc);
    }

    // Update current span to the new child span
    current_span = span;

    return span;
}

/// Get current span (transaction or span)
pub fn getCurrentSpan() ?*Span {
    return current_span;
}

/// Get sentry-trace header value
pub fn getSentryTrace(allocator: Allocator) !?[]u8 {
    if (current_span) |span| {
        return try span.toSentryTrace(allocator);
    } else {
        const propagation_context = scope.getPropagationContext() catch return null;
        const trace_hex = propagation_context.trace_id.toHexFixed();
        const span_hex = propagation_context.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    }
}

/// Get current active transaction
pub fn getCurrentTransaction() ?*Span {
    if (current_span) |span| {
        return span.getTransaction();
    }
    return null;
}
