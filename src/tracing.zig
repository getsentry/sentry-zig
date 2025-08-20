const std = @import("std");
const types = @import("types");
const scope = @import("scope.zig");
const SentryClient = @import("client.zig").SentryClient;

// Top-level type aliases
const TraceId = types.TraceId;
const SpanId = types.SpanId;
const PropagationContext = types.PropagationContext;
const Transaction = types.Transaction;
const TransactionContext = types.TransactionContext;
const TransactionStatus = types.TransactionStatus;
const Span = types.Span;
const Allocator = std.mem.Allocator;

/// Thread-local active transaction stack
threadlocal var active_transaction_stack: ?std.ArrayList(*Transaction) = null;
threadlocal var active_span_stack: ?std.ArrayList(*Span) = null;

/// Initialize tracing thread-local storage
pub fn initTracingTLS(allocator: Allocator) !void {
    if (active_transaction_stack == null) {
        active_transaction_stack = std.ArrayList(*Transaction).init(allocator);
    }
    if (active_span_stack == null) {
        active_span_stack = std.ArrayList(*Span).init(allocator);
    }
}

/// Deinitialize tracing thread-local storage
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

/// Get the currently active transaction, if any
pub fn getActiveTransaction() ?*Transaction {
    if (active_transaction_stack) |*stack| {
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }
    }
    return null;
}

/// Get the currently active span, if any
pub fn getActiveSpan() ?*Span {
    if (active_span_stack) |*stack| {
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }
    }
    return null;
}

/// Start a new transaction
pub fn startTransaction(allocator: Allocator, name: []const u8, op: []const u8) !*Transaction {
    // Get propagation context from current scope
    const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();

    const ctx = TransactionContext.fromPropagationContext(name, op, propagation_context);
    const transaction = try Transaction.init(allocator, ctx);

    // Initialize TLS if needed
    try initTracingTLS(allocator);

    // Push to active transaction stack
    if (active_transaction_stack) |*stack| {
        try stack.append(transaction);
    }

    // Update propagation context in current scope with transaction context
    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    return transaction;
}

/// Start a new transaction from a sentry-trace header
pub fn startTransactionFromHeader(allocator: Allocator, name: []const u8, op: []const u8, sentry_trace: []const u8) !*Transaction {
    var ctx = TransactionContext{
        .name = name,
        .op = op,
    };

    try ctx.updateFromHeader(sentry_trace);
    const transaction = try Transaction.init(allocator, ctx);

    // Initialize TLS if needed
    try initTracingTLS(allocator);

    // Push to active transaction stack
    if (active_transaction_stack) |*stack| {
        try stack.append(transaction);
    }

    // Update propagation context in current scope
    const new_context = transaction.getPropagationContext();
    scope.setTrace(new_context.trace_id, new_context.span_id, new_context.parent_span_id) catch {};

    return transaction;
}

/// Finish and remove the currently active transaction
pub fn finishTransaction() void {
    if (active_transaction_stack) |*stack| {
        if (stack.items.len > 0) {
            if (stack.pop()) |transaction| {
                transaction.finish();

                // Send transaction to Sentry if client is available
                sendTransaction(transaction) catch |err| {
                    std.log.err("Failed to send transaction to Sentry: {}", .{err});
                };
            }
        }
    }
}

/// Start a new span from the current active transaction or span
pub fn startSpan(allocator: Allocator, op: []const u8, description: ?[]const u8) !*Span {
    // Initialize TLS if needed
    try initTracingTLS(allocator);

    var span: *Span = undefined;

    // Try to start span from active span first, then transaction
    if (getActiveSpan()) |active_span| {
        span = try active_span.startSpan(op, description);
    } else if (getActiveTransaction()) |active_transaction| {
        span = try active_transaction.startSpan(op, description);
    } else {
        // No active transaction, create span from current propagation context
        const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();
        span = try Span.init(allocator, op, description, propagation_context.trace_id, propagation_context.span_id);
    }

    // Push to active span stack
    if (active_span_stack) |*stack| {
        try stack.append(span);
    }

    // Update propagation context in current scope
    const span_context = PropagationContext{
        .trace_id = span.trace_id,
        .span_id = span.span_id,
        .parent_span_id = span.parent_span_id,
    };
    scope.setTrace(span_context.trace_id, span_context.span_id, span_context.parent_span_id) catch {};

    return span;
}

/// Finish and remove the currently active span
pub fn finishSpan() void {
    if (active_span_stack) |*stack| {
        if (stack.items.len > 0) {
            if (stack.pop()) |span| {
                span.finish();

                // Restore parent context if any
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

/// Execute a function with a transaction scope
pub fn withTransaction(allocator: Allocator, name: []const u8, op: []const u8, callback: anytype) !void {
    const transaction = try startTransaction(allocator, name, op);
    defer {
        finishTransaction();
        transaction.deinit();
    }

    try callback(transaction);
}

/// Execute a function with a span scope
pub fn withSpan(allocator: Allocator, op: []const u8, description: ?[]const u8, callback: anytype) !void {
    const span = try startSpan(allocator, op, description);
    defer {
        finishSpan();
        // Note: span cleanup is handled by parent transaction/span
    }

    try callback(span);
}

/// Set trace context from incoming trace header (equivalent to sentry_set_trace)
pub fn setTrace(trace_id_hex: []const u8, span_id_hex: []const u8, parent_span_id_hex: ?[]const u8) !void {
    try scope.setTraceFromHex(trace_id_hex, span_id_hex, parent_span_id_hex);
}

/// Get current sentry-trace header value
pub fn getSentryTrace(allocator: Allocator) !?[]u8 {
    if (getActiveSpan()) |span| {
        const trace_hex = span.trace_id.toHexFixed();
        const span_hex = span.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    } else if (getActiveTransaction()) |transaction| {
        return try transaction.toSentryTrace(allocator);
    } else {
        // Return from propagation context
        const propagation_context = scope.getPropagationContext() catch return null;
        const trace_hex = propagation_context.trace_id.toHexFixed();
        const span_hex = propagation_context.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    }
}

/// Send transaction to Sentry through the transport layer
fn sendTransaction(transaction: *Transaction) !void {
    std.log.debug("Attempting to send transaction: {s}", .{transaction.name});

    const client = scope.getClient() orelse {
        std.log.debug("No client available in scope for sending transaction", .{});
        return;
    };

    std.log.debug("Client found, checking if tracing is enabled...", .{});

    // Check if tracing is enabled
    if (!client.options.enable_tracing) {
        std.log.debug("Tracing not enabled, skipping transaction send", .{});
        return;
    }

    std.log.debug("Creating transaction envelope...", .{});

    // Create envelope item from transaction
    const envelope_item = try client.transport.envelopeFromTransaction(transaction);
    defer client.allocator.free(envelope_item.data);

    // Create envelope following the same pattern as events in client.zig
    var buf = [_]types.SentryEnvelopeItem{.{ .data = envelope_item.data, .header = envelope_item.header }};
    const envelope = types.SentryEnvelope{
        .header = types.SentryEnvelopeHeader{
            .event_id = types.EventId.new(), // Generate proper UUID for envelope
        },
        .items = buf[0..],
    };

    std.log.debug("Sending transaction envelope to Sentry...", .{});

    // Send envelope through transport
    const result = try client.transport.send(envelope);

    std.log.debug("Sent transaction to Sentry: {s} (trace: {s}) - Response: {}", .{
        transaction.name,
        &transaction.trace_id.toHexFixed(),
        result.response_code,
    });
}

test "transaction creation and management" {
    const allocator = std.testing.allocator;

    // Initialize scope manager for test
    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const transaction = try startTransaction(allocator, "test_transaction", "http.request");
    defer {
        finishTransaction();
        transaction.deinit();
    }

    try std.testing.expectEqualStrings("test_transaction", transaction.name);
    try std.testing.expectEqualStrings("http.request", transaction.op);
    try std.testing.expect(getActiveTransaction() == transaction);

    deinitTracingTLS();
}

test "span creation and nesting" {
    const allocator = std.testing.allocator;

    // Initialize scope manager for test
    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const transaction = try startTransaction(allocator, "test_transaction", "http.request");
    defer {
        finishTransaction();
        transaction.deinit();
    }

    const span1 = try startSpan(allocator, "db.query", "SELECT users");
    defer finishSpan();

    try std.testing.expect(getActiveSpan() == span1);
    try std.testing.expectEqualStrings("db.query", span1.op);

    const span2 = try startSpan(allocator, "db.connection", "Connect to database");
    defer finishSpan();

    try std.testing.expect(getActiveSpan() == span2);
    try std.testing.expect(span2.parent_span_id.eql(span1.span_id));

    deinitTracingTLS();
}

test "with transaction helper" {
    const allocator = std.testing.allocator;

    // Initialize scope manager for test
    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    try withTransaction(allocator, "test_transaction", "http.request", struct {
        fn callback(transaction: *Transaction) !void {
            try std.testing.expectEqualStrings("test_transaction", transaction.name);
            try std.testing.expect(getActiveTransaction() == transaction);
        }
    }.callback);

    // Should be cleaned up after withTransaction
    try std.testing.expect(getActiveTransaction() == null);

    deinitTracingTLS();
}
