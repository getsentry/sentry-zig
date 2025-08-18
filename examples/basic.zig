const std = @import("std");
const sentry = @import("sentry-zig");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client with options
    const options = sentry.SentryOptions{
        .dsn = "https://your-dsn@sentry.io/project-id", // Replace with your actual DSN
        .environment = "development",
        .release = "1.0.0",
        .debug = true,
        .sample_rate = 1.0,
        .send_default_pii = false,
    };

    var client = try sentry.SentryClient.init(allocator, options);
    defer client.deinit();

    std.log.info("Sentry client initialized successfully!", .{});
    std.log.info("Client is active: {}", .{client.isActive()});

    // Example 1: Capture a simple message
    std.log.info("Capturing a test message...", .{});
    const message_event_id = try client.captureMessage("Hello from Zig!");
    if (message_event_id) |event_id| {
        std.log.info("Message captured with event ID: {s}", .{event_id});
    }

    // Example 2: Capture an exception
    std.log.info("Capturing a test exception...", .{});
    const exception = sentry.Exception{
        .exception_type = "TestError",
        .value = "This is a test exception from the basic example",
        .module = "examples.basic",
        .stacktrace = "main() -> captureError()",
    };
    const error_event_id = try client.captureError(exception);
    if (error_event_id) |event_id| {
        std.log.info("Exception captured with event ID: {s}", .{event_id});
    }

    // Example 3: Capture a custom event
    std.log.info("Capturing a custom event...", .{});
    var tags = std.StringHashMap([]const u8).init(allocator);
    defer tags.deinit();
    try tags.put("example", "basic");
    try tags.put("language", "zig");

    const user = sentry.User{
        .id = "12345",
        .username = "example_user",
        .email = "user@example.com",
    };

    const custom_event = sentry.Event{
        .event_type = "info",
        .message = "Custom event from basic example",
        .user = user,
        .tags = tags,
    };
    const custom_event_id = try client.captureEvent(custom_event);
    if (custom_event_id) |event_id| {
        std.log.info("Custom event captured with event ID: {s}", .{event_id});
    }

    // Flush and close the client
    std.log.info("Flushing events before shutdown...", .{});
    client.flush(5000); // 5 second timeout

    std.log.info("Example completed successfully!", .{});
}
