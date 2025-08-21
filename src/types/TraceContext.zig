const std = @import("std");
const TraceId = @import("TraceId.zig").TraceId;
const SpanId = @import("SpanId.zig").SpanId;
const PropagationContext = @import("PropagationContext.zig").PropagationContext;

/// Trace context for parsing trace headers and creating spans
pub const TraceContext = struct {
    name: []const u8,
    op: []const u8,
    trace_id: ?TraceId = null,
    span_id: ?SpanId = null,
    parent_span_id: ?SpanId = null,
    sampled: ?bool = null,
    description: ?[]const u8 = null,

    /// Update trace context from a trace header (sentry-trace header format)
    pub fn updateFromHeader(self: *TraceContext, sentry_trace: []const u8) !void {
        // Sentry-trace format: "{trace_id}-{span_id}-{sampled}"
        // Example: "12345678901234567890123456789012-1234567890123456-1"

        var parts = std.mem.splitScalar(u8, sentry_trace, '-');

        // Parse trace_id
        const trace_id_str = parts.next() orelse return error.InvalidTraceHeader;
        if (trace_id_str.len != 32) return error.InvalidTraceHeader;
        self.trace_id = try TraceId.fromHex(trace_id_str);

        // Parse span_id (becomes parent_span_id)
        const span_id_str = parts.next() orelse return error.InvalidTraceHeader;
        if (span_id_str.len != 16) return error.InvalidTraceHeader;
        self.parent_span_id = try SpanId.fromHex(span_id_str);

        // Generate new span_id for this transaction
        self.span_id = SpanId.generate();

        // Parse sampled flag
        if (parts.next()) |sampled_str| {
            if (std.mem.eql(u8, sampled_str, "1")) {
                self.sampled = true;
            } else if (std.mem.eql(u8, sampled_str, "0")) {
                self.sampled = false;
            }
            // If not "1" or "0", leave sampled as null (undecided)
        }
    }

    /// Create from propagation context
    pub fn fromPropagationContext(name: []const u8, op: []const u8, context: PropagationContext) TraceContext {
        return TraceContext{
            .name = name,
            .op = op,
            .trace_id = context.trace_id,
            .span_id = SpanId.generate(), // New span ID for transaction
            .parent_span_id = context.parent_span_id,
            .sampled = null,
            .description = null,
        };
    }

    pub fn deinit(self: *TraceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.op);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};
