const std = @import("std");
const sentry = @import("sentry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client with a test DSN
    // Replace with your actual Sentry DSN
    const dsn_string = "https://fd51cdec44d1cb9d27fbc9c0b7149dde@o447951.ingest.us.sentry.io/4509869908951040";

    const options = sentry.SentryOptions{
        .environment = "development",
        .release = "1.0.0-capture-message-demo",
        .debug = true,
        .sample_rate = 1.0,
        .send_default_pii = false,
    };

    var client = sentry.init(allocator, dsn_string, options) catch |err| {
        std.log.err("Failed to initialize Sentry client: {any}", .{err});
        return;
    };
    defer client.deinit();

    std.log.info("=== Sentry captureMessage Demo ===", .{});
    std.log.info("This demo shows how to capture messages with different severity levels", .{});

    // Capture messages with all available levels
    std.log.info("\n1. Capturing DEBUG message...", .{});
    const debug_event_id = sentry.captureMessage("Debug: Application configuration loaded", .debug);
    if (debug_event_id) |event_id| {
        std.log.info("   Event ID: {s}", .{event_id.value});
    }

    std.time.sleep(std.time.ns_per_ms * 500); // Small delay between messages

    std.log.info("\n2. Capturing INFO message...", .{});
    const info_event_id = sentry.captureMessage("Info: User authentication successful", .info);
    if (info_event_id) |event_id| {
        std.log.info("   Event ID: {s}", .{event_id.value});
    }

    std.time.sleep(std.time.ns_per_ms * 500);

    std.log.info("\n3. Capturing WARNING message...", .{});
    const warning_event_id = sentry.captureMessage("Warning: Database connection pool is running low", .warning);
    if (warning_event_id) |event_id| {
        std.log.info("   Event ID: {s}", .{event_id.value});
    }

    std.time.sleep(std.time.ns_per_ms * 500);

    std.log.info("\n4. Capturing ERROR message...", .{});
    const error_event_id = sentry.captureMessage("Error: Failed to process payment transaction", .@"error");
    if (error_event_id) |event_id| {
        std.log.info("   Event ID: {s}", .{event_id.value});
    }

    std.time.sleep(std.time.ns_per_ms * 500);

    std.log.info("\n5. Capturing FATAL message...", .{});
    const fatal_event_id = sentry.captureMessage("Fatal: Critical system failure detected", .fatal);
    if (fatal_event_id) |event_id| {
        std.log.info("   Event ID: {s}", .{event_id.value});
    }

    // Demonstrate capturing messages in different scenarios
    std.log.info("\n=== Scenario-based Examples ===", .{});

    // Simulate application lifecycle events
    _ = sentry.captureMessage("Application startup completed", .info);
    _ = sentry.captureMessage("Cache warmed up successfully", .debug);
    _ = sentry.captureMessage("High memory usage detected: 85%", .warning);
    _ = sentry.captureMessage("Database query timeout exceeded", .@"error");

    // Wait to ensure all messages are sent
    std.log.info("\nWaiting for messages to be sent to Sentry...", .{});
    std.time.sleep(std.time.ns_per_s * 3);

    std.log.info("\n=== Demo Complete ===", .{});
    std.log.info("Check your Sentry dashboard to see all the captured messages!", .{});
    std.log.info("Each message should appear with its respective severity level.", .{});
}
