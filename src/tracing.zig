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
        if (current_scope.getSpan() == transaction) {
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

// ===== TESTS =====

test "Span creation and basic properties" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "test_transaction", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    // Test basic properties
    try std.testing.expect(transaction.?.isTransaction());
    try std.testing.expectEqualStrings("test_transaction", transaction.?.name.?);
    try std.testing.expectEqualStrings("http.request", transaction.?.op);
    try std.testing.expect(transaction.?.sampled == .True);
    try std.testing.expect(transaction.?.start_time > 0);
    try std.testing.expect(transaction.?.parent == null);
}

test "Span parent-child relationships" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "parent_transaction", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    const child_span = try startSpan(allocator, "database.query", "SELECT * FROM users");
    try std.testing.expect(child_span != null);
    defer {
        child_span.?.finish();
        child_span.?.deinit();
        allocator.destroy(child_span.?);
    }

    // Test relationships
    try std.testing.expect(!child_span.?.isTransaction());
    try std.testing.expect(child_span.?.parent == transaction.?);
    try std.testing.expect(std.mem.eql(u8, &child_span.?.trace_id.bytes, &transaction.?.trace_id.bytes));
    try std.testing.expect(std.mem.eql(u8, &child_span.?.parent_span_id.?.bytes, &transaction.?.span_id.bytes));
    try std.testing.expect(child_span.?.getTransaction() == transaction.?);
}

test "Span setTag and setData functionality" {
    const allocator = std.testing.allocator;

    const span = try Span.init(allocator, "test_op", null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    // Test setting tags
    try span.setTag("environment", "test");
    try span.setTag("version", "1.0.0");

    try std.testing.expect(span.tags != null);
    try std.testing.expectEqualStrings("test", span.tags.?.get("environment").?);
    try std.testing.expectEqualStrings("1.0.0", span.tags.?.get("version").?);

    // Test setting data
    try span.setData("user_id", "123");
    try span.setData("request_size", "1024");

    try std.testing.expect(span.data != null);
    try std.testing.expectEqualStrings("123", span.data.?.get("user_id").?);
    try std.testing.expectEqualStrings("1024", span.data.?.get("request_size").?);

    // Test overriding values
    try span.setTag("environment", "production");
    try std.testing.expectEqualStrings("production", span.tags.?.get("environment").?);
}

test "Span toSentryTrace header generation" {
    const allocator = std.testing.allocator;

    var span = Span{
        .trace_id = TraceId.generate(),
        .span_id = SpanId.generate(),
        .parent_span_id = null,
        .op = try allocator.dupe(u8, "test"),
        .start_time = 0,
        .allocator = allocator,
        .sampled = .True,
    };
    defer {
        allocator.free(span.op);
    }

    const trace_header = try span.toSentryTrace(allocator);
    defer allocator.free(trace_header);

    // Should be format: "trace_id-span_id-1"
    var parts = std.mem.splitScalar(u8, trace_header, '-');
    var part_count: u32 = 0;
    while (parts.next()) |_| {
        part_count += 1;
    }

    try std.testing.expectEqual(@as(u32, 3), part_count);
    try std.testing.expect(std.mem.endsWith(u8, trace_header, "-1")); // sampled=true

    // Test unsampled
    span.sampled = .False;
    const trace_header_unsampled = try span.toSentryTrace(allocator);
    defer allocator.free(trace_header_unsampled);
    try std.testing.expect(std.mem.endsWith(u8, trace_header_unsampled, "-0")); // sampled=false
}

test "continueFromHeaders trace propagation" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    // Test with sampled header
    const sentry_trace = "bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1";
    const transaction = try continueFromHeaders(allocator, "continued_transaction", "http.request", sentry_trace);
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    // Verify trace propagation
    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &transaction.?.trace_id.toHexFixed());
    try std.testing.expectEqualStrings("b72fa28504b07285", &transaction.?.parent_span_id.?.toHexFixed());
    try std.testing.expect(transaction.?.sampled == .True);

    // Test with unsampled header
    const sentry_trace_unsampled = "bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-0";
    const unsampled_transaction = try continueFromHeaders(allocator, "unsampled_transaction", "http.request", sentry_trace_unsampled);
    try std.testing.expect(unsampled_transaction != null);
    defer {
        finishTransaction(unsampled_transaction.?);
        unsampled_transaction.?.deinit();
        allocator.destroy(unsampled_transaction.?);
    }

    try std.testing.expect(unsampled_transaction.?.sampled == .False);
}

test "Span sampling decisions" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    // Test with zero sample rate
    {
        const options = types.SentryOptions{
            .sample_rate = 0.0,
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "zero_sample", "test");
        try std.testing.expect(transaction == null); // Should not create transaction
    }

    // Test with full sample rate
    {
        const options = types.SentryOptions{
            .sample_rate = 1.0,
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "full_sample", "test");
        try std.testing.expect(transaction != null);
        defer {
            finishTransaction(transaction.?);
            transaction.?.deinit();
            allocator.destroy(transaction.?);
        }
        try std.testing.expect(transaction.?.sampled == .True);
    }
}

test "TraceContext parsing from headers" {
    var ctx = TraceContext{
        .name = "test",
        .op = "http.request",
    };

    // Test valid header
    try ctx.updateFromHeader("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1");

    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &ctx.trace_id.?.toHexFixed());
    try std.testing.expectEqualStrings("b72fa28504b07285", &ctx.parent_span_id.?.toHexFixed());
    try std.testing.expect(ctx.sampled.? == true);
    try std.testing.expect(ctx.span_id != null); // Should generate new span_id

    // Test header without sampling flag
    var ctx2 = TraceContext{
        .name = "test2",
        .op = "test",
    };
    try ctx2.updateFromHeader("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285");

    try std.testing.expect(ctx2.sampled == null); // Should remain undecided

    // Test invalid header (should return error)
    var ctx3 = TraceContext{
        .name = "test3",
        .op = "test",
    };
    try std.testing.expectError(error.InvalidTraceHeader, ctx3.updateFromHeader("invalid-header"));
}

test "Span status and origin settings" {
    const allocator = std.testing.allocator;

    const span = try Span.init(allocator, "test_op", null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    // Test default values
    try std.testing.expect(span.status == .undefined);
    try std.testing.expect(span.origin == .manual);
    try std.testing.expect(span.source == .custom);

    // Test setting values
    span.status = .ok;
    span.origin = .auto_http;
    span.source = .route;

    try std.testing.expect(span.status == .ok);
    try std.testing.expect(span.origin == .auto_http);
    try std.testing.expect(span.source == .route);
}

test "Span JSON serialization" {
    const allocator = std.testing.allocator;

    const span = try Span.init(allocator, "test_op", null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    try span.setTransactionName("test_transaction");
    try span.setDescription("A test span");
    try span.setTag("environment", "test");
    try span.setData("user_id", "123");
    span.status = .ok;

    // Test that JSON serialization works without error
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    try std.json.stringify(span.*, .{}, json_buffer.writer());

    const json_string = json_buffer.items;
    try std.testing.expect(json_string.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "test_op") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "test_transaction") == null); // name not in JSON for spans
}

test "getCurrentSpan and getCurrentTransaction behavior" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    // No active span initially
    try std.testing.expect(getCurrentSpan() == null);
    try std.testing.expect(getCurrentTransaction() == null);

    const transaction = try startTransaction(allocator, "parent", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    // Transaction is active
    try std.testing.expect(getCurrentSpan() == transaction.?);
    try std.testing.expect(getCurrentTransaction() == transaction.?);

    const child_span = try startSpan(allocator, "database.query", "SELECT users");
    try std.testing.expect(child_span != null);
    defer {
        child_span.?.finish();
        child_span.?.deinit();
        allocator.destroy(child_span.?);
    }

    // Child span is now active
    try std.testing.expect(getCurrentSpan() == child_span.?);
    try std.testing.expect(getCurrentTransaction() == transaction.?); // Still same transaction
}

test "getSentryTrace header generation" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    // No active span - should use propagation context
    {
        const trace_header = try getSentryTrace(allocator);
        try std.testing.expect(trace_header != null);
        defer allocator.free(trace_header.?);

        // Should be format: "trace_id-span_id" (no sampling flag for propagation context)
        const dash_count = std.mem.count(u8, trace_header.?, "-");
        try std.testing.expectEqual(@as(usize, 1), dash_count);
    }

    // With active transaction
    {
        const transaction = try startTransaction(allocator, "test", "http.request");
        try std.testing.expect(transaction != null);
        defer {
            finishTransaction(transaction.?);
            transaction.?.deinit();
            allocator.destroy(transaction.?);
        }

        const trace_header = try getSentryTrace(allocator);
        try std.testing.expect(trace_header != null);
        defer allocator.free(trace_header.?);

        // Should include sampling flag
        try std.testing.expect(std.mem.endsWith(u8, trace_header.?, "-1"));
    }
}

test "Span finish behavior and timing" {
    const allocator = std.testing.allocator;

    const span = try Span.init(allocator, "test_op", null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    // Initially not finished
    try std.testing.expect(!span.finished);
    try std.testing.expect(span.end_time == null);

    const start_time = span.start_time;
    try std.testing.expect(start_time > 0);

    // Sleep briefly to ensure end_time is different
    std.time.sleep(1_000_000); // 1ms

    span.finish();

    // After finishing
    try std.testing.expect(span.finished);
    try std.testing.expect(span.end_time != null);
    try std.testing.expect(span.end_time.? > start_time);

    // Multiple calls to finish should be safe
    span.finish();
    const first_end_time = span.end_time.?;
    span.finish();
    try std.testing.expectEqual(first_end_time, span.end_time.?);
}

test "Span updateFromSentryTrace parsing" {
    const allocator = std.testing.allocator;

    const span = try Span.init(allocator, "test_op", null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    // Valid header with sampling
    const success = span.updateFromSentryTrace("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1");
    try std.testing.expect(success);

    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &span.trace_id.toHexFixed());
    try std.testing.expectEqualStrings("b72fa28504b07285", &span.parent_span_id.?.toHexFixed());
    try std.testing.expect(span.sampled == .True);

    // Invalid header should return false
    const failure = span.updateFromSentryTrace("invalid-header");
    try std.testing.expect(!failure);
}

test "Transaction context creation and integration" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "scope_test", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    // Transaction should be set on scope
    const current_scope = try scope.getCurrentScope();
    try std.testing.expect(current_scope.getSpan() == transaction.?);

    // Test trace headers from scope
    const trace_header = try current_scope.traceHeaders(allocator);
    try std.testing.expect(trace_header != null);
    defer allocator.free(trace_header.?);

    try std.testing.expect(std.mem.endsWith(u8, trace_header.?, "-1"));
}
