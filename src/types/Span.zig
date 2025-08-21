const std = @import("std");
const TraceId = @import("TraceId.zig").TraceId;
const SpanId = @import("SpanId.zig").SpanId;
const Allocator = std.mem.Allocator;
const hashmap_utils = @import("../utils/hashmap_utils.zig");

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

pub const SpanStatus = enum {
    undefined,
    ok,
    cancelled,
    unknown,
    invalid_argument,
    deadline_exceeded,
    not_found,
    already_exists,
    permission_denied,
    resource_exhausted,
    failed_precondition,
    aborted,
    out_of_range,
    unimplemented,
    internal_error,
    unavailable,
    data_loss,
    unauthenticated,

    pub fn toString(self: SpanStatus) []const u8 {
        return switch (self) {
            .undefined => "",
            .cancelled => "cancelled",
            else => @tagName(self),
        };
    }
};

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

pub const TransactionSource = enum {
    custom,
    url,
    route,
    view,
    component,
    task,

    pub fn toString(self: TransactionSource) []const u8 {
        return @tagName(self);
    }
};

/// Span recorder keeps track of all spans in a transaction
const SpanRecorder = struct {
    spans: std.ArrayList(*Span),
    root: ?*Span,
    allocator: Allocator,

    fn init(allocator: Allocator) !*SpanRecorder {
        const recorder = try allocator.create(SpanRecorder);
        recorder.* = SpanRecorder{
            .spans = std.ArrayList(*Span).init(allocator),
            .root = null,
            .allocator = allocator,
        };
        return recorder;
    }

    fn record(self: *SpanRecorder, span: *Span) !void {
        try self.spans.append(span);
        if (span.isTransaction()) {
            self.root = span;
        }
    }

    fn deinit(self: *SpanRecorder) void {
        self.spans.deinit();
    }
};

/// A Span is the building block of a Sentry transaction. Spans build up a tree
/// structure of timed operations. The span tree makes up a transaction event
/// that is sent to Sentry when the root span is finished.
///
/// Transactions are just spans without parents.
pub const Span = struct {
    // Core identification
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,

    // Span metadata
    name: ?[]const u8 = null, // Only set for transactions
    op: []const u8,
    description: ?[]const u8 = null,
    status: SpanStatus = .undefined,

    // Timing (using f64 seconds since epoch like Sentry protocol)
    start_time: f64,
    end_time: ?f64 = null,

    // Additional data
    tags: ?std.StringHashMap([]const u8) = null,
    data: ?std.StringHashMap([]const u8) = null,

    // Sampling and origin
    sampled: Sampled = .Undefined,
    source: TransactionSource = .custom, // Only for transactions
    origin: SpanOrigin = .manual,

    // Memory management
    allocator: Allocator,

    // Relationships
    parent: ?*Span = null, // immediate local parent span
    recorder: ?*SpanRecorder = null, // stores all spans in transaction

    // Contexts (only for transactions)
    contexts: ?std.StringHashMap(std.StringHashMap([]const u8)) = null,

    // State management
    finished: bool = false,

    /// Start a new span. If parent is provided, this creates a child span.
    /// Otherwise, this creates a transaction (root span).
    pub fn init(allocator: Allocator, op: []const u8, parent: ?*Span) !*Span {
        const span = try allocator.create(Span);

        span.* = Span{
            .op = try allocator.dupe(u8, op),
            .start_time = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0,
            .allocator = allocator,
            .parent = parent,
            .trace_id = undefined,
            .span_id = SpanId.generate(),
        };

        // Set trace ID and parent span ID based on parent
        if (parent) |p| {
            span.trace_id = p.trace_id;
            span.parent_span_id = p.span_id;
            span.origin = p.origin;
            span.sampled = p.sampled; // Child spans inherit parent sampling decision
            span.recorder = p.recorder; // Share recorder with parent
        } else {
            // This is a transaction (root span)
            span.trace_id = TraceId.generate();
            span.origin = .manual;
            span.recorder = try SpanRecorder.init(allocator);
        }

        // Record this span in the recorder
        if (span.recorder) |recorder| {
            try recorder.record(span);
        }

        return span;
    }

    /// Check if this span is a transaction (root span)
    pub fn isTransaction(self: *const Span) bool {
        return self.parent == null;
    }

    /// Get the transaction (root span) that contains this span
    pub fn getTransaction(self: *Span) ?*Span {
        if (self.recorder) |recorder| {
            return recorder.root;
        }
        return null;
    }

    /// Start a child span from this span
    pub fn startChild(self: *Span, op: []const u8) !*Span {
        return Span.init(self.allocator, op, self);
    }

    /// Set the transaction name (only valid for transactions)
    pub fn setTransactionName(self: *Span, name: []const u8) !void {
        if (!self.isTransaction()) return;

        if (self.name) |old_name| {
            self.allocator.free(old_name);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    /// Set the description of this span
    pub fn setDescription(self: *Span, description: []const u8) !void {
        if (self.description) |old_desc| {
            self.allocator.free(old_desc);
        }
        self.description = try self.allocator.dupe(u8, description);
    }

    /// Set a tag on the span
    pub fn setTag(self: *Span, key: []const u8, value: []const u8) !void {
        if (self.tags == null) {
            self.tags = std.StringHashMap([]const u8).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

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

        if (self.data.?.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.data.?.put(owned_key, owned_value);
    }

    /// Set context data (only for transactions)
    pub fn setContext(self: *Span, key: []const u8, context_data: std.StringHashMap([]const u8)) !void {
        if (!self.isTransaction()) return;

        if (self.contexts == null) {
            self.contexts = std.StringHashMap(std.StringHashMap([]const u8)).init(self.allocator);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        if (self.contexts.?.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            var old_value = old_entry.value;
            var iterator = old_value.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            old_value.deinit();
        }

        var cloned_context = std.StringHashMap([]const u8).init(self.allocator);
        var context_iterator = context_data.iterator();
        while (context_iterator.next()) |entry| {
            const cloned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const cloned_value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try cloned_context.put(cloned_key, cloned_value);
        }

        try self.contexts.?.put(owned_key, cloned_context);
    }

    /// Generate sentry-trace header value
    pub fn toSentryTrace(self: *const Span, allocator: Allocator) ![]u8 {
        const trace_hex = self.trace_id.toHexFixed();
        const span_hex = self.span_id.toHexFixed();
        const sampled_str = switch (self.sampled) {
            .True => "-1",
            .False => "-0",
            .Undefined => "",
        };

        return try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ trace_hex, span_hex, sampled_str });
    }

    /// Update span from sentry-trace header
    pub fn updateFromSentryTrace(self: *Span, header: []const u8) bool {
        // Parse sentry-trace header format: "trace_id-span_id-sampled"
        var parts = std.mem.splitScalar(u8, header, '-');

        const trace_id_str = parts.next() orelse return false;
        if (trace_id_str.len != 32) return false;

        const span_id_str = parts.next() orelse return false;
        if (span_id_str.len != 16) return false;

        self.trace_id = TraceId.fromHex(trace_id_str) catch return false;

        // Only set parent_span_id for child spans, not transactions
        if (!self.isTransaction()) {
            self.parent_span_id = SpanId.fromHex(span_id_str) catch return false;
        }

        if (parts.next()) |sampled_str| {
            if (std.mem.eql(u8, sampled_str, "1")) {
                self.sampled = .True;
            } else if (std.mem.eql(u8, sampled_str, "0")) {
                self.sampled = .False;
            }
        }

        return true;
    }

    /// Finish the span
    pub fn finish(self: *Span) void {
        if (self.finished) return;

        self.end_time = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
        self.finished = true;
    }

    /// Convert span to Sentry Event (for transactions)
    pub fn toEvent(self: *Span) @import("Event.zig").Event {
        const Event = @import("Event.zig").Event;
        const EventId = @import("Event.zig").EventId;

        var event = Event{
            .allocator = self.allocator,
            .event_id = EventId.new(),
            .timestamp = self.end_time orelse self.start_time,
            .type = "transaction",
            .transaction = self.allocator.dupe(u8, self.name orelse self.op) catch |err| {
                std.log.warn("Failed to duplicate transaction name: {}", .{err});
                return Event{
                    .allocator = self.allocator,
                    .event_id = EventId.new(),
                    .timestamp = self.end_time orelse self.start_time,
                };
            },
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .parent_span_id = null,
            .tags = if (self.tags) |tags| hashmap_utils.cloneStringHashMap(self.allocator, tags) catch null else null,
            .start_time = self.start_time,
            .contexts = null,
        };

        // Add trace context for transactions
        if (self.isTransaction()) {
            var contexts = std.StringHashMap(std.StringHashMap([]const u8)).init(self.allocator);
            var trace_context = std.StringHashMap([]const u8).init(self.allocator);

            // Add required trace context fields
            const trace_id_hex = self.trace_id.toHexFixed();
            const span_id_hex = self.span_id.toHexFixed();

            trace_context.put(self.allocator.dupe(u8, "trace_id") catch return event, self.allocator.dupe(u8, &trace_id_hex) catch return event) catch {};
            trace_context.put(self.allocator.dupe(u8, "span_id") catch return event, self.allocator.dupe(u8, &span_id_hex) catch return event) catch {};
            trace_context.put(self.allocator.dupe(u8, "op") catch return event, self.allocator.dupe(u8, self.op) catch return event) catch {};
            if (self.status != .undefined) {
                trace_context.put(self.allocator.dupe(u8, "status") catch return event, self.allocator.dupe(u8, self.status.toString()) catch return event) catch {};
            }

            contexts.put(self.allocator.dupe(u8, "trace") catch return event, trace_context) catch {};
            event.contexts = contexts;
        }

        if (self.isTransaction() and self.recorder != null) {
            const recorded_spans = self.recorder.?.spans.items;
            if (recorded_spans.len > 1) {
                var child_spans = self.allocator.alloc(Span, recorded_spans.len - 1) catch {
                    std.log.warn("Failed to allocate spans array for transaction", .{});
                    return event;
                };

                var child_count: usize = 0;
                for (recorded_spans) |span| {
                    if (!span.isTransaction()) {
                        child_spans[child_count] = Span{
                            .trace_id = span.trace_id,
                            .span_id = span.span_id,
                            .parent_span_id = span.parent_span_id,
                            .op = self.allocator.dupe(u8, span.op) catch {
                                std.log.warn("Failed to duplicate span op", .{});
                                continue;
                            },
                            .description = if (span.description) |desc| self.allocator.dupe(u8, desc) catch null else null,
                            .status = span.status,
                            .start_time = span.start_time,
                            .end_time = span.end_time,
                            .finished = span.finished,
                            .sampled = span.sampled,
                            .allocator = self.allocator,
                            // Deep copy HashMaps if they exist
                            .tags = if (span.tags) |tags| hashmap_utils.cloneStringHashMap(self.allocator, tags) catch null else null,
                            .data = if (span.data) |data| hashmap_utils.cloneStringHashMap(self.allocator, data) catch null else null,
                            .contexts = null,
                            // These fields are not copied
                            .name = null,
                            .parent = null,
                            .recorder = null,
                        };
                        child_count += 1;
                    }
                }

                event.spans = child_spans[0..child_count];
            }
        }

        return event;
    }

    /// JSON serialization for sending to Sentry (manual due to StringHashMap)
    pub fn jsonStringify(self: Span, jw: anytype) !void {
        const json_utils = @import("../utils/json_utils.zig");

        try jw.beginObject();

        // Core fields
        try jw.objectField("trace_id");
        try jw.write(self.trace_id.toHexFixed());

        try jw.objectField("span_id");
        try jw.write(self.span_id.toHexFixed());

        if (self.parent_span_id) |parent| {
            try jw.objectField("parent_span_id");
            try jw.write(parent.toHexFixed());
        }

        try jw.objectField("op");
        try jw.write(self.op);

        if (self.description) |desc| {
            try jw.objectField("description");
            try jw.write(desc);
        }

        try jw.objectField("start_timestamp");
        try jw.write(self.start_time);

        if (self.end_time) |end| {
            try jw.objectField("timestamp");
            try jw.write(end);
        }

        if (self.status != .undefined) {
            try jw.objectField("status");
            try jw.write(self.status.toString());
        }

        if (self.origin != .manual) {
            try jw.objectField("origin");
            try jw.write(self.origin.toString());
        }

        // Tags
        if (self.tags) |tags| {
            try jw.objectField("tags");
            try json_utils.serializeStringHashMap(tags, jw);
        }

        // Data
        if (self.data) |data| {
            try jw.objectField("data");
            try json_utils.serializeStringHashMap(data, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Span) void {
        self.allocator.free(self.op);

        if (self.name) |name| {
            self.allocator.free(name);
        }

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

        if (self.contexts) |*contexts| {
            var context_iterator = contexts.iterator();
            while (context_iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var inner_iterator = entry.value_ptr.iterator();
                while (inner_iterator.next()) |inner_entry| {
                    self.allocator.free(inner_entry.key_ptr.*);
                    self.allocator.free(inner_entry.value_ptr.*);
                }
                entry.value_ptr.deinit();
            }
            contexts.deinit();
        }

        // Clean up recorder if we own it (transaction only)
        if (self.isTransaction() and self.recorder != null) {
            self.recorder.?.deinit();
            self.allocator.destroy(self.recorder.?);
        }
    }
};
