const std = @import("std");
const sentry = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client with a test DSN
    // Replace with your actual Sentry DSN
    const dsn_string = "https://fd51cdec44d1cb9d27fbc9c0b7149dde@o447951.ingest.us.sentry.io/4509869908951040";

    const options = sentry.SentryOptions{
        .environment = "development",
        .release = "1.0.0",
        .debug = true,
        .sample_rate = 1.0,
        .send_default_pii = false,
    };

    var client = sentry.init(allocator, dsn_string, options) catch |err| {
        std.log.err("Failed to initialize Sentry client: {any}", .{err});
        return;
    };
    defer client.deinit();

    std.log.info("=== Sentry Zig SDK Demo ===", .{});
    std.log.info("This is a basic demonstration of the Sentry Zig SDK", .{});
    std.log.info("For more examples, run:", .{});
    std.log.info("  zig build panic_handler", .{});
    std.log.info("  zig build send_empty_envelope", .{});
    std.log.info("  zig build capture_message_demo", .{});

    // Capture a simple message
    const event_id = sentry.captureMessage("Hello from Sentry Zig SDK!", .info);
    if (event_id) |id| {
        std.log.info("Message sent with Event ID: {s}", .{id.value});
    } else {
        std.log.warn("Failed to capture message", .{});
    }
}
