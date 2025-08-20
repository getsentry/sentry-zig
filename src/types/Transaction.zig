const std = @import("std");
const TraceId = @import("TraceId.zig").TraceId;
const SpanId = @import("SpanId.zig").SpanId;
const PropagationContext = @import("PropagationContext.zig").PropagationContext;
const EventId = @import("Event.zig").EventId;

pub const Sampled = enum(i8) {
    False = -1,
    Undefined = 0,
    True = 1,

    pub fn fromBool(value: ?bool) Sampled {
        return if (value) |v| (if (v) .True else .False) else .Undefined;
    }

    pub fn toBool(self: Sampled) bool {
        return self == .True;
    }
};

/// Transaction context for creating transactions
pub const TransactionContext = struct {
    name: []const u8,
    op: []const u8,
    trace_id: ?TraceId = null,
    span_id: ?SpanId = null,
    parent_span_id: ?SpanId = null,
    sampled: ?bool = null,
    description: ?[]const u8 = null,

    /// Update transaction context from a trace header (sentry-trace header format)
    pub fn updateFromHeader(self: *TransactionContext, sentry_trace: []const u8) !void {
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
    pub fn fromPropagationContext(name: []const u8, op: []const u8, context: PropagationContext) TransactionContext {
        return TransactionContext{
            .name = name,
            .op = op,
            .trace_id = context.trace_id,
            .span_id = SpanId.generate(), // New span ID for transaction
            .parent_span_id = context.parent_span_id,
            .sampled = null,
            .description = null,
        };
    }

    pub fn deinit(self: *TransactionContext, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.op);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

/// Transaction status
pub const TransactionStatus = enum {
    ok,
    deadline_exceeded,
    unauthenticated,
    permission_denied,
    not_found,
    resource_exhausted,
    invalid_argument,
    unimplemented,
    unavailable,
    internal_error,
    unknown_error,
    cancelled,
    already_exists,
    failed_precondition,
    aborted,
    out_of_range,
    data_loss,

    pub fn toString(self: TransactionStatus) []const u8 {
        return @tagName(self);
    }
};

/// A transaction represents a single unit of work or operation
pub const Transaction = struct {
    // Transaction identification
    name: []const u8,
    op: []const u8,
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,

    // Transaction metadata
    description: ?[]const u8 = null,
    status: ?TransactionStatus = null,
    sampled: Sampled = .Undefined,

    // Timing
    start_timestamp: f64,
    timestamp: ?f64 = null, // End timestamp when finished

    // Additional data
    tags: ?std.StringHashMap([]const u8) = null,
    data: ?std.StringHashMap([]const u8) = null,

    // Child spans
    spans: std.ArrayList(*Span),

    // Memory management
    allocator: std.mem.Allocator,
    finished: bool = false,

    /// Create a new transaction from context
    pub fn init(allocator: std.mem.Allocator, context: TransactionContext) !*Transaction {
        const transaction = try allocator.create(Transaction);

        transaction.* = Transaction{
            .name = try allocator.dupe(u8, context.name),
            .op = try allocator.dupe(u8, context.op),
            .trace_id = context.trace_id orelse TraceId.generate(),
            .span_id = context.span_id orelse SpanId.generate(),
            .parent_span_id = context.parent_span_id,
            .description = if (context.description) |desc| try allocator.dupe(u8, desc) else null,
            .sampled = Sampled.fromBool(context.sampled),
            .start_timestamp = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0,
            .spans = std.ArrayList(*Span).init(allocator),
            .allocator = allocator,
        };

        return transaction;
    }

    /// Finish the transaction
    pub fn finish(self: *Transaction) void {
        if (self.finished) return;

        self.timestamp = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
        self.finished = true;
    }

    /// Convert transaction to Event for Sentry protocol
    pub fn toEvent(self: *Transaction) @import("Event.zig").Event {
        const Event = @import("Event.zig").Event;

        return Event{
            .event_id = @import("Event.zig").EventId.new(),
            .timestamp = self.timestamp orelse self.start_timestamp,
            .type = "transaction",
            .transaction = self.name,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = self.parent_span_id,
            .tags = self.tags,
            // Note: spans and data fields would need special handling for full transaction events
            // but this covers the basic event conversion
        };
    }

    /// Set transaction status
    pub fn setStatus(self: *Transaction, status: TransactionStatus) void {
        self.status = status;
    }

    /// Set a tag on the transaction
    pub fn setTag(self: *Transaction, key: []const u8, value: []const u8) !void {
        if (self.tags == null) {
            self.tags = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

        // Remove old entry if exists
        if (self.tags.?.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.tags.?.put(owned_key, owned_value);
    }

    /// Set arbitrary data on the transaction
    pub fn setData(self: *Transaction, key: []const u8, value: []const u8) !void {
        if (self.data == null) {
            self.data = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

        // Remove old entry if exists
        if (self.data.?.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.data.?.put(owned_key, owned_value);
    }

    /// Start a child span
    pub fn startSpan(self: *Transaction, op: []const u8, description: ?[]const u8) !*Span {
        const span = try Span.init(
            self.allocator,
            op,
            description,
            self.trace_id,
            self.span_id, // This transaction becomes the parent
        );

        try self.spans.append(span);
        return span;
    }

    /// Get the propagation context for this transaction
    pub fn getPropagationContext(self: Transaction) PropagationContext {
        return PropagationContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = self.parent_span_id,
        };
    }

    /// Generate sentry-trace header value
    pub fn toSentryTrace(self: Transaction, allocator: std.mem.Allocator) ![]u8 {
        const trace_hex = self.trace_id.toHexFixed();
        const span_hex = self.span_id.toHexFixed();
        const sampled_str = switch (self.sampled) {
            .True => "-1",
            .False => "-0",
            .Undefined => "",
        };

        return try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ trace_hex, span_hex, sampled_str });
    }

    /// JSON serialization for transactions
    pub fn jsonStringify(self: Transaction, jw: anytype) !void {
        try jw.beginObject();

        // Required fields for Sentry transactions
        try jw.objectField("event_id");
        const event_id = EventId.new();
        try jw.write(event_id.value);

        try jw.objectField("type");
        try jw.write("transaction");

        try jw.objectField("platform");
        try jw.write("native");

        try jw.objectField("transaction");
        try jw.write(self.name);

        try jw.objectField("op");
        try jw.write(self.op);

        try jw.objectField("trace_id");
        try jw.write(self.trace_id.toHexFixed());

        try jw.objectField("span_id");
        try jw.write(self.span_id.toHexFixed());

        try jw.objectField("start_timestamp");
        try jw.write(self.start_timestamp);

        // Optional fields
        if (self.parent_span_id) |parent| {
            try jw.objectField("parent_span_id");
            try jw.write(parent.toHexFixed());
        }

        if (self.description) |desc| {
            try jw.objectField("description");
            try jw.write(desc);
        }

        if (self.timestamp) |ts| {
            try jw.objectField("timestamp");
            try jw.write(ts);
        }

        if (self.status) |status| {
            try jw.objectField("status");
            try jw.write(status.toString());
        }

        if (self.sampled != .Undefined) {
            try jw.objectField("sampled");
            try jw.write(self.sampled.toBool());
        }

        // Tags
        if (self.tags) |tags| {
            try jw.objectField("tags");
            try jw.beginObject();
            var tag_iter = tags.iterator();
            while (tag_iter.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }

        // Data
        if (self.data) |data| {
            try jw.objectField("data");
            try jw.beginObject();
            var data_iter = data.iterator();
            while (data_iter.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }

        // Spans - always include even if empty
        try jw.objectField("spans");
        try jw.beginArray();
        for (self.spans.items) |span| {
            try jw.write(span.*);
        }
        try jw.endArray();

        // Required contexts field
        try jw.objectField("contexts");
        try jw.beginObject();
        try jw.objectField("trace");
        try jw.beginObject();
        try jw.objectField("trace_id");
        try jw.write(self.trace_id.toHexFixed());
        try jw.objectField("span_id");
        try jw.write(self.span_id.toHexFixed());
        if (self.parent_span_id) |parent| {
            try jw.objectField("parent_span_id");
            try jw.write(parent.toHexFixed());
        }
        try jw.endObject();
        try jw.endObject();

        try jw.endObject();
    }

    pub fn deinit(self: *Transaction) void {
        self.allocator.free(self.name);
        self.allocator.free(self.op);

        if (self.description) |desc| {
            self.allocator.free(desc);
        }

        if (self.tags) |*tags| {
            var tag_iter = tags.iterator();
            while (tag_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            tags.deinit();
        }

        if (self.data) |*data| {
            var data_iter = data.iterator();
            while (data_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            data.deinit();
        }

        // Clean up spans
        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.deinit();

        self.allocator.destroy(self);
    }
};

/// A span represents a single operation within a transaction
pub const Span = struct {
    op: []const u8,
    description: ?[]const u8 = null,
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: SpanId,

    // Timing
    start_timestamp: f64,
    timestamp: ?f64 = null, // End timestamp when finished

    // Metadata
    status: ?TransactionStatus = null,
    tags: ?std.StringHashMap([]const u8) = null,
    data: ?std.StringHashMap([]const u8) = null,

    // Child spans
    spans: std.ArrayList(*Span),

    // Memory management
    allocator: std.mem.Allocator,
    finished: bool = false,

    /// Create a new span
    pub fn init(allocator: std.mem.Allocator, op: []const u8, description: ?[]const u8, trace_id: TraceId, parent_span_id: SpanId) !*Span {
        const span = try allocator.create(Span);

        span.* = Span{
            .op = try allocator.dupe(u8, op),
            .description = if (description) |desc| try allocator.dupe(u8, desc) else null,
            .trace_id = trace_id,
            .span_id = SpanId.generate(),
            .parent_span_id = parent_span_id,
            .start_timestamp = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0,
            .spans = std.ArrayList(*Span).init(allocator),
            .allocator = allocator,
        };

        return span;
    }

    /// Finish the span
    pub fn finish(self: *Span) void {
        if (!self.finished) {
            self.timestamp = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
            self.finished = true;
        }
    }

    /// Set span status
    pub fn setStatus(self: *Span, status: TransactionStatus) void {
        self.status = status;
    }

    /// Set a tag on the span
    pub fn setTag(self: *Span, key: []const u8, value: []const u8) !void {
        if (self.tags == null) {
            self.tags = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

        // Remove old entry if exists
        if (self.tags.?.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.tags.?.put(owned_key, owned_value);
    }

    /// Set arbitrary data on the span
    pub fn setData(self: *Span, key: []const u8, value: []const u8) !void {
        if (self.data == null) {
            self.data = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

        // Remove old entry if exists
        if (self.data.?.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.data.?.put(owned_key, owned_value);
    }

    /// Start a child span
    pub fn startSpan(self: *Span, op: []const u8, description: ?[]const u8) !*Span {
        const child_span = try Span.init(
            self.allocator,
            op,
            description,
            self.trace_id,
            self.span_id, // This span becomes the parent
        );

        try self.spans.append(child_span);
        return child_span;
    }

    /// JSON serialization for spans
    pub fn jsonStringify(self: Span, jw: anytype) !void {
        try jw.beginObject();

        // Required fields
        try jw.objectField("op");
        try jw.write(self.op);

        try jw.objectField("trace_id");
        try jw.write(self.trace_id.toHexFixed());

        try jw.objectField("span_id");
        try jw.write(self.span_id.toHexFixed());

        try jw.objectField("parent_span_id");
        try jw.write(self.parent_span_id.toHexFixed());

        try jw.objectField("start_timestamp");
        try jw.write(self.start_timestamp);

        // Optional fields
        if (self.description) |desc| {
            try jw.objectField("description");
            try jw.write(desc);
        }

        if (self.timestamp) |ts| {
            try jw.objectField("timestamp");
            try jw.write(ts);
        }

        if (self.status) |status| {
            try jw.objectField("status");
            try jw.write(status.toString());
        }

        // Tags
        if (self.tags) |tags| {
            try jw.objectField("tags");
            try jw.beginObject();
            var tag_iter = tags.iterator();
            while (tag_iter.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }

        // Data
        if (self.data) |data| {
            try jw.objectField("data");
            try jw.beginObject();
            var data_iter = data.iterator();
            while (data_iter.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.write(entry.value_ptr.*);
            }
            try jw.endObject();
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Span) void {
        self.allocator.free(self.op);

        if (self.description) |desc| {
            self.allocator.free(desc);
        }

        if (self.tags) |*tags| {
            var tag_iter = tags.iterator();
            while (tag_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            tags.deinit();
        }

        if (self.data) |*data| {
            var data_iter = data.iterator();
            while (data_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            data.deinit();
        }

        // Clean up child spans
        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.deinit();
    }
};

test "TransactionContext updateFromHeader" {
    var ctx = TransactionContext{
        .name = "test",
        .op = "http.request",
    };

    try ctx.updateFromHeader("12345678901234567890123456789012-1234567890123456-1");

    try std.testing.expectEqualStrings("12345678901234567890123456789012", &ctx.trace_id.?.toHexFixed());
    try std.testing.expectEqualStrings("1234567890123456", &ctx.parent_span_id.?.toHexFixed());
    try std.testing.expect(ctx.sampled.? == true);
    try std.testing.expect(ctx.span_id != null); // Should have generated new span_id
}

test "Transaction creation and basic operations" {
    const allocator = std.testing.allocator;

    const ctx = TransactionContext{
        .name = "test_transaction",
        .op = "http.request",
        .description = "Test HTTP request",
    };

    const transaction = try Transaction.init(allocator, ctx);
    defer transaction.deinit();

    try std.testing.expectEqualStrings("test_transaction", transaction.name);
    try std.testing.expectEqualStrings("http.request", transaction.op);
    try std.testing.expectEqualStrings("Test HTTP request", transaction.description.?);
    try std.testing.expect(transaction.start_timestamp > 0);
    try std.testing.expect(!transaction.finished);

    transaction.finish();
    try std.testing.expect(transaction.finished);
    try std.testing.expect(transaction.timestamp != null);
}

test "Transaction span creation" {
    const allocator = std.testing.allocator;

    const ctx = TransactionContext{
        .name = "test_transaction",
        .op = "http.request",
    };

    const transaction = try Transaction.init(allocator, ctx);
    defer transaction.deinit();

    const span = try transaction.startSpan("db.query", "SELECT * FROM users");

    try std.testing.expectEqualStrings("db.query", span.op);
    try std.testing.expectEqualStrings("SELECT * FROM users", span.description.?);
    try std.testing.expect(span.trace_id.eql(transaction.trace_id));
    try std.testing.expect(span.parent_span_id.eql(transaction.span_id));
    try std.testing.expectEqual(@as(usize, 1), transaction.spans.items.len);
}

test "Span creation and nesting" {
    const allocator = std.testing.allocator;

    const parent_span = try Span.init(
        allocator,
        "parent.op",
        "Parent operation",
        TraceId.generate(),
        SpanId.generate(),
    );
    defer {
        parent_span.deinit();
        allocator.destroy(parent_span);
    }

    const child_span = try parent_span.startSpan("child.op", "Child operation");

    try std.testing.expectEqualStrings("child.op", child_span.op);
    try std.testing.expectEqualStrings("Child operation", child_span.description.?);
    try std.testing.expect(child_span.trace_id.eql(parent_span.trace_id));
    try std.testing.expect(child_span.parent_span_id.eql(parent_span.span_id));
    try std.testing.expectEqual(@as(usize, 1), parent_span.spans.items.len);
}
