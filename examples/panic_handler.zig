const std = @import("std");
const sentry = @import("sentry_zig");

// Set up the panic handler to use Sentry's panic handler
pub const panic = std.debug.FullPanic(sentry.panicHandler);

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
    abc();
}

fn abc() void {
    // Add some work to prevent inlining
    const x = calculateSomething(42);
    std.log.debug("Calling foo with value: {}", .{x});

    // Use @call with .never_inline to force separate stack frame
    @call(.never_inline, foo, .{});
}

fn foo() void {
    // Add some work to prevent inlining
    const y = calculateSomething(24);
    std.log.debug("About to panic with value: {}", .{y});

    // Force the function to be non-trivial with volatile operations
    var volatile_array: [1000]u8 = undefined;
    for (&volatile_array, 0..) |*item, i| {
        item.* = @intCast(i % 256);
    }
    // Force the array to be used - cannot be optimized away
    _ = &volatile_array;

    @panic("This is a test panic to demonstrate Sentry panic handling!");
}

// Helper function to prevent inlining
fn calculateSomething(input: u32) u32 {
    var result: u32 = input;
    result = result * 2 + 1;
    return result;
}
