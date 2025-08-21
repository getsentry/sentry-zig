const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const types = @import("types");
const Transport = @import("transport.zig").HttpTransport;
const scope = @import("scope.zig");

// Top-level type aliases
const Dsn = types.Dsn;
const Event = types.Event;
const EventId = types.EventId;
const Exception = types.Exception;
const User = types.User;
const SentryOptions = types.SentryOptions;
const SentryEnvelope = types.SentryEnvelope;
const SentryEnvelopeHeader = types.SentryEnvelopeHeader;
const SentryEnvelopeItem = types.SentryEnvelopeItem;
const SDKPackage = types.SDKPackage;
const SDK = types.SDK;

var SDK_INFO = [_]SDKPackage{
    SDKPackage{
        .name = "sentry-zig",
        .version = "0.1.0",
    },
};

pub const SentryClient = struct {
    options: SentryOptions,
    active: bool,
    allocator: Allocator,
    transport: Transport,

    pub fn init(allocator: Allocator, dsn: ?[]const u8, options: SentryOptions) !SentryClient {
        var opts = options;

        // Parse DSN if provided
        if (dsn) |dsn_str| {
            opts.dsn = try Dsn.parse(allocator, dsn_str);
        }

        const client = SentryClient{
            .options = opts,
            .active = opts.dsn != null,
            .allocator = allocator,
            .transport = Transport.init(allocator, &opts),
        };

        if (opts.debug) {
            std.log.debug("Initializing Sentry client", .{});
            if (opts.dsn) |parsed_dsn| {
                const dsn_str = try parsed_dsn.toString(allocator);
                defer allocator.free(dsn_str);
                std.log.debug("DSN: {s}", .{dsn_str});
                std.log.debug("Host: {s}:{d}", .{ parsed_dsn.host, parsed_dsn.port });
                std.log.debug("Project ID: {s}", .{parsed_dsn.project_id});
            }
            if (opts.environment) |env| {
                std.log.debug("Environment: {s}", .{env});
            }
            std.log.debug("Sample rate: {d}", .{opts.sample_rate});
        }

        return client;
    }

    pub fn isActive(self: *const SentryClient) bool {
        return self.active;
    }

    /// Capture an event and return its ID if successful
    pub fn captureEvent(self: *SentryClient, event: Event) !?[32]u8 {
        if (!self.isActive()) {
            if (self.options.debug) {
                std.log.debug("Client is not active (no DSN configured)", .{});
            }
            return null;
        }

        const prepared_event = try self.prepareEvent(event);

        if (self.options.debug) {
            std.log.debug("Capturing event with ID: {s}", .{prepared_event.event_id.value});
            if (prepared_event.message) |msg| {
                std.log.debug("Message: {s}", .{msg.message});
            }
        }

        const envelope_item = try self.transport.envelopeFromEvent(prepared_event);
        defer self.allocator.free(envelope_item.data); // Free the allocated data

        var buf = [_]SentryEnvelopeItem{.{ .data = envelope_item.data, .header = envelope_item.header }};
        const envelope = SentryEnvelope{
            .header = SentryEnvelopeHeader{
                .event_id = prepared_event.event_id,
            },
            .items = buf[0..],
        };

        _ = try self.transport.send(envelope);

        return prepared_event.event_id.value;
    }

    /// Capture an exception
    pub fn captureError(self: *SentryClient, exception: Exception) !?[32]u8 {
        const event = Event{
            .event_id = EventId.new(),
            .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
            .platform = "zig",
            .exception = exception,
        };

        return self.captureEvent(event);
    }

    /// Capture a simple message
    pub fn captureMessage(self: *SentryClient, message: []const u8) !?[32]u8 {
        const event = Event{
            .event_id = EventId.new(),
            .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
            .platform = "zig",
            .message = .{ .message = message },
        };

        return self.captureEvent(event);
    }

    /// Prepare an event by adding client metadata
    fn prepareEvent(self: *SentryClient, event: Event) !Event {
        var prepared = event;

        // Add SDK info
        if (prepared.sdk == null) {
            prepared.sdk = SDK{
                .name = "sentry.zig",
                .version = "0.1.0", //TODO: get version from somewhere instead of hardcoding it
                .packages = SDK_INFO[0..],
            };
        }

        // Add environment from options
        if (prepared.environment == null and self.options.environment != null) {
            prepared.environment = self.options.environment;
        }

        // Add release from options
        if (prepared.release == null and self.options.release != null) {
            prepared.release = self.options.release;
        }

        // TODO:
        // - Apply event processors
        // - Add contextual data

        return prepared;
    }

    pub fn flush(self: *SentryClient, timeout: ?u64) void {
        _ = self;
        _ = timeout;
        // TODO: Implement flush logic (delegate to transport layer)
        // For now, just sleep for a bit as dummy implementation
        std.time.sleep(1_000_000_000); // 1 second
    }

    pub fn close(self: *SentryClient, timeout: ?u64) void {
        // TODO: Implement close logic (delegate to transport layer)
        self.active = false;
        self.flush(timeout);
    }

    pub fn deinit(self: *SentryClient) void {
        if (self.options.debug) {
            std.log.debug("Shutting down Sentry client", .{});
        }
        self.close(null);
        self.transport.deinit();
        self.options.deinit();
    }
};

// Example usage
test "basic client initialization" {
    const allocator = std.testing.allocator;

    // Initialize options
    const options = SentryOptions{
        .environment = "testing",
        .release = "1.0.0",
        .debug = true,
        .sample_rate = 0.5,
        .send_default_pii = true,
    };

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    try std.testing.expect(client.isActive());
    try std.testing.expectEqualStrings("testing", client.options.environment.?);
    try std.testing.expectEqual(@as(f64, 0.5), client.options.sample_rate);
}

test "initialization with DSN string" {
    const allocator = std.testing.allocator;

    // Initialize options
    const options = SentryOptions{
        .send_default_pii = true,
    };

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    try std.testing.expect(client.isActive());
    try std.testing.expect(client.options.environment == null); // default is null
}

test "capture message" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    const event_id = try client.captureMessage("Test message");
    try std.testing.expect(event_id != null);
}

test "inactive client returns null" {
    const allocator = std.testing.allocator;

    // No DSN provided
    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, null, options);
    defer client.deinit();

    try std.testing.expect(!client.isActive());

    const event_id = try client.captureMessage("Test message");
    try std.testing.expect(event_id == null);
}

test "capture exception" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    const exception = Exception{
        .type = "RuntimeError",
        .value = "Something went wrong",
        .module = "main",
    };

    const event_id = try client.captureError(exception);
    try std.testing.expect(event_id != null);
}

test "event ID generation is UUID v4 compatible" {
    // Generate several IDs to ensure they're unique and properly formatted
    var seen_ids = std.hash_map.StringHashMap(void).init(std.testing.allocator);
    defer {
        // Free all the allocated strings
        var iter = seen_ids.iterator();
        while (iter.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
        }
        seen_ids.deinit();
    }

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const event_id = EventId.new();
        const id = event_id.value;

        // Check length
        try std.testing.expectEqual(@as(usize, 32), id.len);

        // Check all characters are valid hex
        for (id) |char| {
            try std.testing.expect((char >= '0' and char <= '9') or (char >= 'a' and char <= 'f'));
        }

        // Check uniqueness
        const id_string = try std.testing.allocator.dupe(u8, &id);
        try std.testing.expect(!seen_ids.contains(id_string));
        try seen_ids.put(id_string, {});

        // Verify it's a valid UUID v4 format (version bits)
        // In hex position 12 (byte 6), the first nibble should be 4
        const version_nibble = if (id[12] >= 'a') id[12] - 'a' + 10 else id[12] - '0';
        try std.testing.expectEqual(@as(u8, 4), version_nibble);

        // In hex position 16 (byte 8), the first nibble should be 8, 9, a, or b
        const variant_nibble = if (id[16] >= 'a') id[16] - 'a' + 10 else id[16] - '0';
        try std.testing.expect(variant_nibble >= 8 and variant_nibble <= 11);
    }
}
