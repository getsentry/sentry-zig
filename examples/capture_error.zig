const std = @import("std");
const sentry = @import("sentry_zig");

const MyError = error{
    FileNotFound,
    PermissionDenied,
    OutOfMemory,
};

fn doSomethingThatMightFail() !void {
    // Simulate some operation that fails
    return MyError.FileNotFound;
}

fn processFile() !void {
    try doSomethingThatMightFail();
}

fn performTask() !void {
    try processFile();
}

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

    // Perform an operation that might fail
    performTask() catch |err| {
        std.debug.print("Caught error: {}\n", .{err});

        // Capture the error with automatic stack trace capture
        const event_id = try sentry.captureError(allocator, err);

        if (event_id) |id| {
            std.debug.print("Error sent to Sentry with ID: {s}\n", .{id.value});
        }
    };

    // Also demonstrate capturing a standalone error
    const some_error = error.UnexpectedCondition;
    const event_id2 = try sentry.captureError(allocator, some_error);
    if (event_id2) |id| {
        std.debug.print("Error sent to Sentry with ID: {s}\n", .{id.value});
    }

    std.debug.print("Example completed successfully!\n", .{});
}
