const std = @import("std");
const TraceId = @import("TraceId.zig").TraceId;
const SpanId = @import("SpanId.zig").SpanId;

/// Propagation context for distributed tracing
/// Contains trace_id and span_id used for connecting events across boundaries
pub const PropagationContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,

    /// Generate a new propagation context with random trace_id and span_id
    pub fn generate() PropagationContext {
        return PropagationContext{
            .trace_id = TraceId.generate(),
            .span_id = SpanId.generate(),
            .parent_span_id = null,
        };
    }

    /// Create propagation context from hex strings
    pub fn fromHex(trace_id_hex: []const u8, span_id_hex: []const u8, parent_span_id_hex: ?[]const u8) !PropagationContext {
        const trace_id = try TraceId.fromHex(trace_id_hex);
        const span_id = try SpanId.fromHex(span_id_hex);

        const parent_span_id = if (parent_span_id_hex) |hex|
            try SpanId.fromHex(hex)
        else
            null;

        return PropagationContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span_id,
        };
    }

    /// Create a child context (same trace_id, new span_id, current span_id becomes parent)
    pub fn createChild(self: PropagationContext) PropagationContext {
        return PropagationContext{
            .trace_id = self.trace_id,
            .span_id = SpanId.generate(),
            .parent_span_id = self.span_id,
        };
    }

    /// Update context from incoming trace data (used by sentry_set_trace equivalent)
    pub fn updateFromTrace(self: *PropagationContext, trace_id: TraceId, span_id: SpanId, parent_span_id: ?SpanId) void {
        self.trace_id = trace_id;
        self.span_id = span_id;
        self.parent_span_id = parent_span_id;
    }

    /// Clone the propagation context
    pub fn clone(self: PropagationContext) PropagationContext {
        return PropagationContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = self.parent_span_id,
        };
    }

    /// Get trace_id as hex string (allocates)
    pub fn getTraceIdHex(self: PropagationContext, allocator: std.mem.Allocator) ![]u8 {
        return self.trace_id.toHex(allocator);
    }

    /// Get span_id as hex string (allocates)
    pub fn getSpanIdHex(self: PropagationContext, allocator: std.mem.Allocator) ![]u8 {
        return self.span_id.toHex(allocator);
    }

    /// Get parent_span_id as hex string (allocates), null if no parent
    pub fn getParentSpanIdHex(self: PropagationContext, allocator: std.mem.Allocator) !?[]u8 {
        if (self.parent_span_id) |parent| {
            return try parent.toHex(allocator);
        }
        return null;
    }

    /// JSON serialization
    pub fn jsonStringify(self: PropagationContext, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("trace_id");
        try jw.write(self.trace_id);

        try jw.objectField("span_id");
        try jw.write(self.span_id);

        if (self.parent_span_id) |parent| {
            try jw.objectField("parent_span_id");
            try jw.write(parent);
        }

        try jw.endObject();
    }
};

test "PropagationContext generation" {
    const ctx1 = PropagationContext.generate();
    const ctx2 = PropagationContext.generate();

    // Should have valid IDs
    try std.testing.expect(!ctx1.trace_id.isNil());
    try std.testing.expect(!ctx1.span_id.isNil());
    try std.testing.expect(ctx1.parent_span_id == null);

    // Should be different
    try std.testing.expect(!ctx1.trace_id.eql(ctx2.trace_id));
    try std.testing.expect(!ctx1.span_id.eql(ctx2.span_id));
}

test "PropagationContext fromHex" {
    const ctx = try PropagationContext.fromHex("12345678901234567890123456789012", "1234567890123456", "abcdefabcdefabcd");

    try std.testing.expectEqualStrings("12345678901234567890123456789012", &ctx.trace_id.toHexFixed());
    try std.testing.expectEqualStrings("1234567890123456", &ctx.span_id.toHexFixed());
    try std.testing.expectEqualStrings("abcdefabcdefabcd", &ctx.parent_span_id.?.toHexFixed());
}

test "PropagationContext createChild" {
    const parent = PropagationContext.generate();
    const child = parent.createChild();

    // Should have same trace_id
    try std.testing.expect(parent.trace_id.eql(child.trace_id));

    // Should have different span_id
    try std.testing.expect(!parent.span_id.eql(child.span_id));

    // Parent's span_id should become child's parent_span_id
    try std.testing.expect(parent.span_id.eql(child.parent_span_id.?));
}

test "PropagationContext updateFromTrace" {
    var ctx = PropagationContext.generate();
    const original_trace_id = ctx.trace_id;

    const new_trace_id = TraceId.generate();
    const new_span_id = SpanId.generate();
    const new_parent_span_id = SpanId.generate();

    ctx.updateFromTrace(new_trace_id, new_span_id, new_parent_span_id);

    try std.testing.expect(ctx.trace_id.eql(new_trace_id));
    try std.testing.expect(ctx.span_id.eql(new_span_id));
    try std.testing.expect(ctx.parent_span_id.?.eql(new_parent_span_id));
    try std.testing.expect(!ctx.trace_id.eql(original_trace_id));
}

test "PropagationContext hex operations" {
    const allocator = std.testing.allocator;
    const ctx = PropagationContext.generate();

    const trace_hex = try ctx.getTraceIdHex(allocator);
    defer allocator.free(trace_hex);
    try std.testing.expectEqual(@as(usize, 32), trace_hex.len);

    const span_hex = try ctx.getSpanIdHex(allocator);
    defer allocator.free(span_hex);
    try std.testing.expectEqual(@as(usize, 16), span_hex.len);

    // Test parent span ID (should be null for generated context)
    const parent_hex = try ctx.getParentSpanIdHex(allocator);
    try std.testing.expect(parent_hex == null);
}

test "PropagationContext clone" {
    const original = PropagationContext.generate();
    const cloned = original.clone();

    try std.testing.expect(original.trace_id.eql(cloned.trace_id));
    try std.testing.expect(original.span_id.eql(cloned.span_id));
    try std.testing.expect(original.parent_span_id == null and cloned.parent_span_id == null);
}
