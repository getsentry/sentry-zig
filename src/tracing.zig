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

// Import SamplingContext
const SamplingContext = types.SamplingContext;

threadlocal var current_span: ?*Span = null;

fn isTracingEnabled(client: *const SentryClient) bool {
    return client.options.sample_rate != null;
}

fn isPerformanceTracingEnabled(client: *const SentryClient) bool {
    const rate = client.options.sample_rate orelse return false;
    return rate > 0.0;
}

fn sampleSpan(span: *Span, client: *const SentryClient, ctx: *const TraceContext) Sampled {
    if (client.options.sample_rate == null) {
        std.log.debug("Dropping transaction: tracing is not enabled", .{});
        return .False;
    }

    if (!span.isTransaction() and span.parent != null) {
        std.log.debug("Using parent sampling decision: {}", .{span.parent.?.sampled});
        return span.parent.?.sampled;
    }

    if (client.options.traces_sampler) |sampler| {
        const sampling_context = SamplingContext{
            .span = span,
            .parent = span.parent,
            .trace_context = ctx,
            .name = span.name,
        };

        const sampler_rate = sampler(sampling_context);
        std.log.debug("TracesSampler returned rate: {d}", .{sampler_rate});

        if (sampler_rate < 0.0 or sampler_rate > 1.0) {
            std.log.debug("Dropping transaction: TracesSampler rate out of range [0.0, 1.0]: {d}", .{sampler_rate});
            return .False;
        }

        if (sampler_rate == 0.0) {
            return .False;
        }

        if (generateSampleDecision(sampler_rate)) {
            return .True;
        }

        std.log.debug("Dropping transaction: random >= TracesSampler rate {d}", .{sampler_rate});
        return .False;
    }

    if (ctx.sampled) |sampled| {
        std.log.debug("Using sampling decision from header: {?}", .{sampled});
        return if (sampled) .True else .False;
    }

    const sample_rate = client.options.sample_rate.?;

    if (sample_rate <= 0.0) {
        std.log.debug("Dropping transaction: sample_rate is {d}", .{sample_rate});
        return .False;
    }

    if (sample_rate >= 1.0) {
        return .True;
    }

    if (generateSampleDecision(sample_rate)) {
        return .True;
    }

    return .False;
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

pub fn startTransaction(allocator: Allocator, name: []const u8, op: []const u8) !?*Span {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction", .{});
        return null;
    };

    if (!isTracingEnabled(client)) {
        std.log.debug("Tracing disabled - no propagation context update", .{});
        return null;
    }

    const propagation_context = scope.getPropagationContext() catch PropagationContext.generate();

    const new_span_id = SpanId.generate();
    scope.setTrace(propagation_context.trace_id, new_span_id, propagation_context.span_id) catch {};

    if (!isPerformanceTracingEnabled(client)) {
        std.log.debug("Tracing without Performance mode - no span created", .{});
        return null;
    }

    const transaction = try Span.init(allocator, op, null);
    try transaction.setTransactionName(name);

    transaction.trace_id = propagation_context.trace_id;
    transaction.span_id = new_span_id;
    transaction.parent_span_id = propagation_context.span_id;

    const ctx = TraceContext.fromPropagationContext(name, op, propagation_context);
    const sampling_decision = sampleSpan(transaction, client, &ctx);

    if (sampling_decision == .False) {
        transaction.deinit();
        allocator.destroy(transaction);
        return null;
    }

    transaction.sampled = sampling_decision;

    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    current_span = transaction;

    return transaction;
}

pub fn continueFromHeaders(allocator: Allocator, name: []const u8, op: []const u8, sentry_trace: []const u8) !?*Span {
    const client = scope.getClient() orelse {
        std.log.debug("No client available, cannot start transaction from header", .{});
        return null;
    };

    if (!isTracingEnabled(client)) {
        std.log.debug("Tracing disabled - ignoring incoming trace headers", .{});
        return null;
    }

    var ctx = TraceContext{
        .name = name,
        .op = op,
    };
    try ctx.updateFromHeader(sentry_trace);

    scope.setTrace(ctx.trace_id.?, ctx.span_id.?, ctx.parent_span_id) catch {};

    if (!isPerformanceTracingEnabled(client)) {
        std.log.debug("TwP mode - propagation context updated, no span created", .{});
        return null;
    }

    const transaction = try Span.init(allocator, op, null);
    try transaction.setTransactionName(name);

    _ = transaction.updateFromSentryTrace(sentry_trace);

    const sampling_decision = sampleSpan(transaction, client, &ctx);
    transaction.sampled = sampling_decision;

    if (scope.getCurrentScope() catch null) |current_scope| {
        current_scope.setSpan(transaction);
    }

    current_span = transaction;

    return transaction;
}

pub fn finishTransaction(transaction: *Span) void {
    if (!transaction.isTransaction()) {
        std.log.warn("finishTransaction called on non-root span", .{});
        return;
    }

    transaction.finish();

    if (scope.getCurrentScope() catch null) |current_scope| {
        if (current_scope.getSpan() == transaction) {
            current_scope.setSpan(null);
        }
    }

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

    // Create event and properly clean it up after sending
    var event = transaction.toEvent();
    defer event.deinit();

    const event_id = try scope.captureEvent(event);

    if (event_id) |id| {
        std.log.debug("Span sent to Sentry with event ID: {s}", .{id.value});
    } else {
        std.log.debug("Span was not sent (filtered or no client)", .{});
    }
}

pub fn startSpan(allocator: Allocator, op: []const u8, description: ?[]const u8) !?*Span {
    const parent_span = current_span orelse {
        std.log.debug("No active span, cannot start child span", .{});
        return null;
    };

    if (parent_span.sampled != .True) {
        std.log.debug("Parent span not sampled, skipping span creation", .{});
        return null;
    }

    const span = try Span.init(allocator, op, parent_span);
    if (description) |desc| {
        try span.setDescription(desc);
    }

    current_span = span;

    return span;
}

pub fn getCurrentSpan() ?*Span {
    return current_span;
}

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

    try span.setTag("environment", "test");
    try span.setTag("version", "1.0.0");

    try std.testing.expect(span.tags != null);
    try std.testing.expectEqualStrings("test", span.tags.?.get("environment").?);
    try std.testing.expectEqualStrings("1.0.0", span.tags.?.get("version").?);

    try span.setData("user_id", "123");
    try span.setData("request_size", "1024");

    try std.testing.expect(span.data != null);
    try std.testing.expectEqualStrings("123", span.data.?.get("user_id").?);
    try std.testing.expectEqualStrings("1024", span.data.?.get("request_size").?);

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

    var parts = std.mem.splitScalar(u8, trace_header, '-');
    var part_count: u32 = 0;
    while (parts.next()) |_| {
        part_count += 1;
    }

    try std.testing.expectEqual(@as(u32, 3), part_count);
    try std.testing.expect(std.mem.endsWith(u8, trace_header, "-1"));

    // Test unsampled
    span.sampled = .False;
    const trace_header_unsampled = try span.toSentryTrace(allocator);
    defer allocator.free(trace_header_unsampled);
    try std.testing.expect(std.mem.endsWith(u8, trace_header_unsampled, "-0"));
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

    const sentry_trace = "bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1";
    const transaction = try continueFromHeaders(allocator, "continued_transaction", "http.request", sentry_trace);
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &transaction.?.trace_id.toHexFixed());
    try std.testing.expect(transaction.?.parent_span_id == null); // Transactions should not have parent_span_id
    try std.testing.expect(transaction.?.sampled == .True);

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

    {
        const options = types.SentryOptions{
            .sample_rate = 0.0,
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "zero_sample", "test");
        try std.testing.expect(transaction == null);
    }

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
    try std.testing.expect(ctx.span_id != null);

    // Test header without sampling flag
    var ctx2 = TraceContext{
        .name = "test2",
        .op = "test",
    };
    try ctx2.updateFromHeader("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285");

    try std.testing.expect(ctx2.sampled == null);

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

    try std.testing.expect(span.status == .undefined);
    try std.testing.expect(span.origin == .manual);
    try std.testing.expect(span.source == .custom);

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

    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    try std.json.stringify(span.*, .{}, json_buffer.writer());

    const json_string = json_buffer.items;
    try std.testing.expect(json_string.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "test_op") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "test_transaction") == null);
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

    try std.testing.expect(getCurrentSpan() == null);
    try std.testing.expect(getCurrentTransaction() == null);

    const transaction = try startTransaction(allocator, "parent", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    try std.testing.expect(getCurrentSpan() == transaction.?);
    try std.testing.expect(getCurrentTransaction() == transaction.?);

    const child_span = try startSpan(allocator, "database.query", "SELECT users");
    try std.testing.expect(child_span != null);
    defer {
        child_span.?.finish();
        child_span.?.deinit();
        allocator.destroy(child_span.?);
    }

    try std.testing.expect(getCurrentSpan() == child_span.?);
    try std.testing.expect(getCurrentTransaction() == transaction.?);
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

    {
        const trace_header = try getSentryTrace(allocator);
        try std.testing.expect(trace_header != null);
        defer allocator.free(trace_header.?);

        const dash_count = std.mem.count(u8, trace_header.?, "-");
        try std.testing.expectEqual(@as(usize, 1), dash_count);
    }

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

    try std.testing.expect(!span.finished);
    try std.testing.expect(span.end_time == null);

    const start_time = span.start_time;
    try std.testing.expect(start_time > 0);

    std.time.sleep(1_000_000);

    span.finish();

    try std.testing.expect(span.finished);
    try std.testing.expect(span.end_time != null);
    try std.testing.expect(span.end_time.? > start_time);

    span.finish();
    const first_end_time = span.end_time.?;
    span.finish();
    try std.testing.expectEqual(first_end_time, span.end_time.?);
}

test "Span updateFromSentryTrace parsing" {
    const allocator = std.testing.allocator;

    // Test with transaction (no parent)
    const transaction = try Span.init(allocator, "test_op", null);
    defer {
        transaction.deinit();
        allocator.destroy(transaction);
    }

    const success = transaction.updateFromSentryTrace("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1");
    try std.testing.expect(success);

    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &transaction.trace_id.toHexFixed());
    try std.testing.expect(transaction.parent_span_id == null); // Transactions should not have parent_span_id
    try std.testing.expect(transaction.sampled == .True);

    // Test with child span (has parent)
    const child_span = try Span.init(allocator, "child_op", transaction);
    defer {
        child_span.deinit();
        allocator.destroy(child_span);
    }

    const child_success = child_span.updateFromSentryTrace("bc6d53f15eb88f4320054569b8c553d4-b72fa28504b07285-1");
    try std.testing.expect(child_success);

    try std.testing.expectEqualStrings("bc6d53f15eb88f4320054569b8c553d4", &child_span.trace_id.toHexFixed());
    try std.testing.expectEqualStrings("b72fa28504b07285", &child_span.parent_span_id.?.toHexFixed());
    try std.testing.expect(child_span.sampled == .True);

    const failure = transaction.updateFromSentryTrace("invalid-header");
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

    const current_scope = try scope.getCurrentScope();
    try std.testing.expect(current_scope.getSpan() == transaction.?);

    const trace_header = try current_scope.traceHeaders(allocator);
    try std.testing.expect(trace_header != null);
    defer allocator.free(trace_header.?);

    try std.testing.expect(std.mem.endsWith(u8, trace_header.?, "-1"));
}

test "Tracing without Performance (TwP) vs Performance modes" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    {
        const options = types.SentryOptions{
            .sample_rate = null,
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "no_trace", "http.request");
        try std.testing.expect(transaction == null);
    }

    {
        const options = types.SentryOptions{
            .sample_rate = 0.0, // TwP mode
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "twp_transaction", "http.request");
        try std.testing.expect(transaction == null);

        const propagation_context = try scope.getPropagationContext();
        try std.testing.expect(propagation_context.trace_id.bytes.len == 16);
    }

    {
        const options = types.SentryOptions{
            .sample_rate = 1.0,
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        const transaction = try startTransaction(allocator, "perf_transaction", "http.request");
        try std.testing.expect(transaction != null);
        defer {
            finishTransaction(transaction.?);
            transaction.?.deinit();
            allocator.destroy(transaction.?);
        }

        try std.testing.expect(transaction.?.sampled == .True);
    }
}

test "Event trace context inheritance" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    {
        const options = types.SentryOptions{
            .sample_rate = 0.0, // TwP mode
        };
        var client = try SentryClient.init(allocator, null, options);
        defer client.transport.deinit();
        scope.setClient(&client);

        // Create event
        var event = types.Event{
            .event_id = types.EventId.new(),
            .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
            .platform = "zig",
            .message = .{ .message = "Test message" },
        };

        // Apply scope to event
        const current_scope = try scope.getCurrentScope();
        try current_scope.applyToEvent(&event);

        try std.testing.expect(event.trace_id != null);
        try std.testing.expect(event.span_id != null);
    }

    {
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

        // Create event
        var event = types.Event{
            .event_id = types.EventId.new(),
            .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
            .platform = "zig",
            .message = .{ .message = "Test message" },
        };

        const current_scope = try scope.getCurrentScope();
        try current_scope.applyToEvent(&event);

        try std.testing.expect(event.trace_id != null);
        try std.testing.expect(std.mem.eql(u8, &event.trace_id.?.bytes, &transaction.?.trace_id.bytes));
        // Event should have its own span_id (different from transaction)
        try std.testing.expect(event.span_id != null);
        try std.testing.expect(!std.mem.eql(u8, &event.span_id.?.bytes, &transaction.?.span_id.bytes));
        // Event's parent should be the transaction
        try std.testing.expect(event.parent_span_id != null);
        try std.testing.expect(std.mem.eql(u8, &event.parent_span_id.?.bytes, &transaction.?.span_id.bytes));
    }
}

test "Child span inheritance and sampling" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const options = types.SentryOptions{
        .sample_rate = 1.0,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    // Create parent transaction
    const transaction = try startTransaction(allocator, "parent", "http.request");
    try std.testing.expect(transaction != null);
    defer {
        finishTransaction(transaction.?);
        transaction.?.deinit();
        allocator.destroy(transaction.?);
    }

    // Create child span
    const child = try startSpan(allocator, "database.query", "SELECT users");
    try std.testing.expect(child != null);
    defer {
        child.?.finish();
        child.?.deinit();
        allocator.destroy(child.?);
    }

    try std.testing.expect(std.mem.eql(u8, &child.?.trace_id.bytes, &transaction.?.trace_id.bytes));
    try std.testing.expect(std.mem.eql(u8, &child.?.parent_span_id.?.bytes, &transaction.?.span_id.bytes));
    try std.testing.expect(child.?.sampled == transaction.?.sampled);

    {
        const options_unsampled = types.SentryOptions{
            .sample_rate = 0.5,
        };
        var client_unsampled = try SentryClient.init(allocator, null, options_unsampled);
        defer client_unsampled.transport.deinit();
        scope.setClient(&client_unsampled);

        const unsampled_transaction = try startTransaction(allocator, "unsampled", "test");
        if (unsampled_transaction) |ut| {
            ut.sampled = .False;
            current_span = ut;

            const no_child = try startSpan(allocator, "should.fail", "Not created");
            try std.testing.expect(no_child == null);

            ut.deinit();
            allocator.destroy(ut);
        }
    }
}

test "setTrace propagation context update" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    // Get initial propagation context
    const initial_context = try scope.getPropagationContext();
    const initial_trace_id = initial_context.trace_id;

    var new_trace_id = TraceId{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 15 };
    var new_span_id = SpanId{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 7 };
    var parent_span_id = SpanId{ .bytes = [_]u8{0x03} ++ [_]u8{0x00} ** 7 };

    try scope.setTrace(new_trace_id, new_span_id, parent_span_id);

    const updated_context = try scope.getPropagationContext();
    try std.testing.expect(!std.mem.eql(u8, &updated_context.trace_id.bytes, &initial_trace_id.bytes));
    try std.testing.expect(std.mem.eql(u8, &updated_context.trace_id.bytes, &new_trace_id.bytes));
    try std.testing.expect(std.mem.eql(u8, &updated_context.span_id.bytes, &new_span_id.bytes));
    try std.testing.expect(std.mem.eql(u8, &updated_context.parent_span_id.?.bytes, &parent_span_id.bytes));
}

test "TracesSampler callback functionality" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const TestSampler = struct {
        fn sampleFunction(ctx: SamplingContext) f64 {
            _ = ctx;
            return 0.8;
        }
    };

    const options = types.SentryOptions{
        .sample_rate = 1.0, // This will be overridden by traces_sampler
        .traces_sampler = TestSampler.sampleFunction,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    var sampled_count: u32 = 0;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const transaction = try startTransaction(allocator, "test_transaction", "test");
        if (transaction) |tx| {
            sampled_count += 1;
            finishTransaction(tx);
            tx.deinit();
            allocator.destroy(tx);
        }
    }

    try std.testing.expect(sampled_count > 10);
    try std.testing.expect(sampled_count < 20);
}

test "TracesSampler priority over sample_rate" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const ZeroSampler = struct {
        fn sampleFunction(ctx: SamplingContext) f64 {
            _ = ctx;
            return 0.0;
        }
    };

    const options = types.SentryOptions{
        .sample_rate = 1.0,
        .traces_sampler = ZeroSampler.sampleFunction,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "zero_sampled", "test");
    try std.testing.expect(transaction == null);
}

test "TracesSampler with parent sampling context" {
    const allocator = std.testing.allocator;

    try scope.initScopeManager(allocator);
    defer scope.resetAllScopeState(allocator);

    const ParentRespectingSampler = struct {
        fn sampleFunction(ctx: SamplingContext) f64 {
            if (ctx.parent_sample_rate) |parent_rate| {
                return parent_rate;
            }

            return 0.5;
        }
    };

    const options = types.SentryOptions{
        .sample_rate = 1.0,
        .traces_sampler = ParentRespectingSampler.sampleFunction,
    };
    var client = try SentryClient.init(allocator, null, options);
    defer client.transport.deinit();
    scope.setClient(&client);

    const transaction = try startTransaction(allocator, "parent_test", "test");
    if (transaction) |tx| {
        defer {
            finishTransaction(tx);
            tx.deinit();
            allocator.destroy(tx);
        }

        try std.testing.expect(tx.sampled != .Undefined);
    }
}
