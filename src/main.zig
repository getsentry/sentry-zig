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

    @panic("This is a test panic to demonstrate Sentry integration!");
}
