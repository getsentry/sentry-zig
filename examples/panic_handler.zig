const std = @import("std");
const sentry = @import("sentry_zig");

// Set up the panic handler to use Sentry's panic handler
pub const panic = std.debug.FullPanic(sentry.panic_handler);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client
    const dsn_string = "https://fd51cdec44d1cb9d27fbc9c0b7149dde@o447951.ingest.us.sentry.io/4509869908951040";

    const options = sentry.SentryOptions{
        .environment = "development",
        .release = "1.0.0-panic-handler-demo",
        .debug = true,
        .sample_rate = 1.0,
        .send_default_pii = false,
    };

    var client = sentry.init(allocator, dsn_string, options) catch |err| {
        std.log.err("Failed to initialize Sentry client: {any}", .{err});
        return;
    };
    defer client.deinit();

    std.log.info("Panic Handler Demo - triggering panic to test Sentry integration", .{});

    // Trigger a panic to demonstrate the panic handler
    @panic("This is a test panic to demonstrate Sentry panic handling!");
}
