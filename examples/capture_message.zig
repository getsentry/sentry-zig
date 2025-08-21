const std = @import("std");
const sentry = @import("sentry_zig");

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

    const client = sentry.init(allocator, dsn_string, options) catch |err| {
        std.log.err("Failed to initialize Sentry client: {any}", .{err});
        return;
    };
    defer sentry.shutdown(allocator, client);

    std.log.info("Sentry captureMessage Demo", .{});

    // Capture messages with different severity levels
    _ = try sentry.captureMessage("Debug: Application configuration loaded", .debug);
    _ = try sentry.captureMessage("Info: User authentication successful", .info);
    _ = try sentry.captureMessage("Warning: Database connection pool is running low", .warning);
    _ = try sentry.captureMessage("Error: Failed to process payment transaction", .@"error");
    _ = try sentry.captureMessage("Fatal: Critical system failure detected", .fatal);

    // A dditional scenario examples
    _ = try sentry.captureMessage("Application startup completed", .info);
    _ = try sentry.captureMessage("Cache warmed up successfully", .debug);
    _ = try sentry.captureMessage("High memory usage detected: 85%", .warning);
    _ = try sentry.captureMessage("Database query timeout exceeded", .@"error");

    std.log.info("Messages sent to Sentry. Check your dashboard!", .{});
    std.time.sleep(std.time.ns_per_s * 2);
}
