const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Dsn = @import("types/Dsn.zig").Dsn;
const Event = @import("types/Event.zig").Event;
const EventId = @import("types/Event.zig").EventId;
const Exception = @import("types/Event.zig").Exception;
const SDK = @import("types/Event.zig").SDK;
const SDKPackage = @import("types/Event.zig").SDKPackage;
const User = @import("types/User.zig").User;
const SentryOptions = @import("types/SentryOptions.zig").SentryOptions;
const scope = @import("scope.zig");
const test_utils = @import("test_utils.zig");

pub const SentryClient = struct {
    options: SentryOptions,
    active: bool,
    allocator: Allocator,

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
    pub fn captureEvent(self: *SentryClient, event: Event, scope_ptr: ?*scope.Scope) !?[32]u8 {
        if (!self.isActive()) {
            if (self.options.debug) {
                std.log.debug("Client is not active (no DSN configured)", .{});
            }
            return null;
        }

        const prepared_event = try self.prepareEvent(event, scope_ptr);

        if (self.options.debug) {
            std.log.debug("Capturing event with ID: {s}", .{prepared_event.event_id.value});
            if (prepared_event.message) |msg| {
                std.log.debug("Message: {s}", .{msg.message});
            }
        }

        // TODO: Delegate to transport layer

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

        return self.captureEvent(event, null);
    }

    /// Capture a simple message
    pub fn captureMessage(self: *SentryClient, message: []const u8) !?[32]u8 {
        const event = Event{
            .event_id = EventId.new(),
            .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
            .platform = "zig",
            .message = .{ .message = message },
        };

        return self.captureEvent(event, null);
    }

    fn prepareEvent(self: *SentryClient, event: Event, scope_ptr: ?*scope.Scope) !Event {
        var prepared = event;

        // Apply scope data if provided
        if (scope_ptr) |scope_data| {
            try scope_data.applyToEvent(&prepared, self.allocator);
        }

        // Add SDK info
        if (prepared.sdk == null) {
            var packages = [_]SDKPackage{
                SDKPackage{
                    .name = "sentry-zig",
                    .version = "0.1.0",
                },
            };
            prepared.sdk = SDK{
                .name = "sentry.zig",
                .version = "0.1.0", //TODO: get version from somewhere instead of hardcoding it
                .packages = packages[0..],
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
        // Cleanup options (including DSN)
        self.options.deinit(self.allocator);
        // TODO: additional cleanup logic
        self.close(null);
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

test "scope processing - initialization" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    // Test that scope manager was initialized and client is active
    try std.testing.expect(client.isActive());
}

test "scope processing - explicit scope" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, "https://key@sentry.io/1", options);
    defer client.deinit();

    // Create a scope manually
    var test_scope = scope.Scope.init(allocator);
    defer test_scope.deinit();

    // Set some data on the scope
    try test_scope.setTag("test_tag", "test_value");
    test_scope.level = @import("types/Level.zig").Level.warning;

    // Create an event
    const event = Event{
        .event_id = EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "zig",
        .message = .{ .message = "Test message with scope" },
    };

    // For testing, we need to prepare the event ourselves to clean it up
    var prepared_event = try client.prepareEvent(event, &test_scope);
    defer test_utils.cleanupEventForTesting(allocator, &prepared_event);

    // Just verify the event was prepared correctly
    try std.testing.expect(prepared_event.tags != null);
    try std.testing.expect(prepared_event.tags.?.contains("test_tag"));
    try std.testing.expect(prepared_event.level == @import("types/Level.zig").Level.warning);
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
