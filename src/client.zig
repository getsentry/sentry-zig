const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;

pub const SentryOptions = struct {
    dsn: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    debug: bool = false,
    sample_rate: f64 = 1.0,
    send_default_pii: bool = false,
};

//DUMMY STRUCTURES
pub const Event = struct {
    event_id: ?[32]u8 = null,

    timestamp: ?i64 = null,

    event_type: []const u8 = "error",

    platform: []const u8 = "zig",

    message: ?[]const u8 = null,

    exception: ?Exception = null,

    extra: ?std.json.ObjectMap = null,

    user: ?User = null,

    tags: ?std.StringHashMap([]const u8) = null,
};

/// Exception data structure
pub const Exception = struct {
    exception_type: []const u8,

    value: ?[]const u8 = null,

    module: ?[]const u8 = null,

    stacktrace: ?[]const u8 = null,
};

/// User context information
pub const User = struct {
    id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    email: ?[]const u8 = null,
    ip_address: ?[]const u8 = null,
};
//END DUMMY STRUCTURES

pub const SentryClient = struct {
    options: SentryOptions,
    active: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: SentryOptions) !SentryClient {
        const client = SentryClient{
            .options = options,
            .active = options.dsn != null,
            .allocator = allocator,
        };

        if (options.debug) {
            std.log.debug("Initializing Sentry client", .{});
            if (options.dsn) |dsn| {
                std.log.debug("DSN: {s}", .{dsn});
            }
            if (options.environment) |env| {
                std.log.debug("Environment: {s}", .{env});
            }
            std.log.debug("Sample rate: {d}", .{options.sample_rate});
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
            std.log.debug("Capturing event: {s}", .{prepared_event.event_type});
            if (prepared_event.message) |msg| {
                std.log.debug("Message: {s}", .{msg});
            }
        }

        // TODO: Delegate to transport layer

        return prepared_event.event_id;
    }

    /// Capture an exception
    pub fn captureException(self: *SentryClient, exception: Exception) !?[32]u8 {
        const event = Event{
            .event_type = "error",
            .exception = exception,
        };

        return self.captureEvent(event);
    }

    /// Capture a simple message
    pub fn captureMessage(self: *SentryClient, message: []const u8) !?[32]u8 {
        const event = Event{
            .event_type = "message",
            .message = message,
        };

        return self.captureEvent(event);
    }

    /// Prepare an event by adding client metadata
    fn prepareEvent(_: *SentryClient, event: Event) !Event {
        var prepared = event;

        if (prepared.event_id == null) {
            prepared.event_id = generateEventId();
        }

        if (prepared.timestamp == null) {
            prepared.timestamp = std.time.timestamp();
        }

        // TODO:
        // - Add SDK info
        // - Add environment from options
        // - Add release from options
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
        // TODO: cleanup logic
        self.close(null);
    }
};

// VIBE CODE WARNING
// The following code is completely vibe coded.

// Thread-local PRNG for event ID generation with counter for uniqueness
threadlocal var event_id_prng: ?Random.DefaultPrng = null;
threadlocal var event_id_counter: u64 = 0;

/// Generate a unique event ID (UUID v4 compatible)
fn generateEventId() [32]u8 {
    // Initialize PRNG if not already done
    if (event_id_prng == null) {
        // Combine multiple sources for better seed entropy
        var seed: u64 = 0;
        seed ^= @as(u64, @intCast(std.time.nanoTimestamp()));
        seed ^= @as(u64, @intFromPtr(&event_id_counter));
        seed ^= std.Thread.getCurrentId();
        event_id_prng = Random.DefaultPrng.init(seed);
    }

    // Increment counter for additional uniqueness
    event_id_counter +%= 1;

    // Generate 16 random bytes (128 bits) for UUID v4
    var uuid_bytes: [16]u8 = undefined;
    const random = event_id_prng.?.random();
    random.bytes(&uuid_bytes);

    // Mix in the counter to ensure uniqueness even with same seed
    uuid_bytes[0] ^= @as(u8, @truncate(event_id_counter));
    uuid_bytes[1] ^= @as(u8, @truncate(event_id_counter >> 8));

    // Set version (4) and variant bits according to UUID v4 spec
    uuid_bytes[6] = (uuid_bytes[6] & 0x0F) | 0x40; // Version 4
    uuid_bytes[8] = (uuid_bytes[8] & 0x3F) | 0x80; // Variant 10

    // Convert to hex string (32 characters)
    var hex_id: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";

    for (uuid_bytes, 0..) |byte, i| {
        hex_id[i * 2] = hex_chars[byte >> 4];
        hex_id[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex_id;
}

// Example usage
test "basic client initialization" {
    const allocator = std.testing.allocator;

    // Option 1: Most explicit, using struct initialization
    const options = SentryOptions{
        .dsn = "https://key@sentry.io/project",
        .environment = "testing",
        .release = "1.0.0",
        .debug = true,
        .sample_rate = 0.5,
        .send_default_pii = true,
    };

    var client = try SentryClient.init(allocator, options);
    defer client.deinit();

    try std.testing.expect(client.isActive());
    try std.testing.expectEqualStrings("testing", client.options.environment.?);
    try std.testing.expectEqual(@as(f64, 0.5), client.options.sample_rate);
}

test "initialization with anonymous struct" {
    const allocator = std.testing.allocator;

    // Option 2: More concise with anonymous struct literal
    var client = try SentryClient.init(allocator, .{
        .dsn = "https://key@sentry.io/project",
        .send_default_pii = true,
        // Other fields use defaults
    });
    defer client.deinit();

    try std.testing.expect(client.isActive());
    try std.testing.expect(client.options.environment == null); // default is null
}

test "capture message" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{
        .dsn = "https://key@sentry.io/project",
    };

    var client = try SentryClient.init(allocator, options);
    defer client.deinit();

    const event_id = try client.captureMessage("Test message");
    try std.testing.expect(event_id != null);
}

test "inactive client returns null" {
    const allocator = std.testing.allocator;

    // No DSN provided
    const options = SentryOptions{};

    var client = try SentryClient.init(allocator, options);
    defer client.deinit();

    try std.testing.expect(!client.isActive());

    const event_id = try client.captureMessage("Test message");
    try std.testing.expect(event_id == null);
}

test "capture exception" {
    const allocator = std.testing.allocator;

    const options = SentryOptions{
        .dsn = "https://key@sentry.io/project",
    };

    var client = try SentryClient.init(allocator, options);
    defer client.deinit();

    const exception = Exception{
        .exception_type = "RuntimeError",
        .value = "Something went wrong",
        .module = "main",
    };

    const event_id = try client.captureException(exception);
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
        const id = generateEventId();

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
