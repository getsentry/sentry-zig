const std = @import("std");
const sentry = @import("root.zig");
const panic_handler = @import("panic_handler.zig");
pub const panic = std.debug.FullPanic(panic_handler.panic_handler);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client with a test DSN
    // Replace with your actual Sentry DSN
    const dsn_string = "https://7c8df91eb303287546fa8eb371154766@o447951.ingest.us.sentry.io/4509869908951040";

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

    // Demonstrate captureMessage with different levels
    std.log.info("Capturing messages with different levels...", .{});

    _ = sentry.captureMessage("Application started successfully", .info);
    std.log.info("Sent info message", .{});

    _ = sentry.captureMessage("This is a warning message", .warning);
    std.log.info("Sent warning message", .{});

    _ = sentry.captureMessage("This is a debug message", .debug);
    std.log.info("Sent debug message", .{});

    _ = sentry.captureMessage("This is an error message", .@"error");
    std.log.info("Sent error message", .{});

    // Wait a bit to ensure messages are sent
    std.time.sleep(std.time.ns_per_s * 2);

    std.log.info("Demo completed. Check your Sentry dashboard for the messages!", .{});

    // Uncomment the line below to also trigger a panic
    // @panic("This is a test panic to demonstrate Sentry integration!");
}
