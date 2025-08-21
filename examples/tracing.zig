const std = @import("std");
const sentry = @import("sentry_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry client with performance tracing enabled
    // Replace with your actual Sentry DSN
    const dsn_string = "https://fd51cdec44d1cb9d27fbc9c0b7149dde@o447951.ingest.us.sentry.io/4509869908951040";

    const options = sentry.SentryOptions{
        .environment = "development",
        .release = "1.0.0-tracing-demo",
        .debug = true,
        .sample_rate = 1.0, // Enable Performance tracing (100% sample rate)
        .send_default_pii = false,
    };

    var client = sentry.init(allocator, dsn_string, options) catch |err| {
        std.log.err("Failed to initialize Sentry client: {any}", .{err});
        return;
    };
    defer {
        client.deinit();
        allocator.destroy(client);
    }

    std.log.info("=== Sentry Tracing Demo ===", .{});

    // === BASIC TRANSACTION EXAMPLE ===
    std.log.info("1. Creating a basic transaction", .{});

    const transaction = try sentry.startTransaction(allocator, "http.request", "GET /api/users");
    if (transaction) |tx| {
        defer {
            sentry.finishTransaction(tx);
            tx.deinit();
            allocator.destroy(tx);
        }

        // Set transaction metadata
        try tx.setTag("method", "GET");
        try tx.setTag("endpoint", "/api/users");
        try tx.setData("user_id", "12345");
        try tx.setDescription("Fetch user list from database");
        tx.status = .ok;

        std.log.info("Transaction created with trace_id: {s}", .{&tx.trace_id.toHexFixed()});

        const db_span = try sentry.startSpan(allocator, "db.query", "SELECT * FROM users");
        if (db_span) |db| {
            defer {
                db.finish();
                db.deinit();
                allocator.destroy(db);
            }

            try db.setTag("db.operation", "SELECT");
            try db.setTag("table", "users");
            try db.setData("query", "SELECT id, name, email FROM users WHERE active = true");
            db.status = .ok;

            std.log.info("Database span created: {s}", .{&db.span_id.toHexFixed()});

            const cache_span = try sentry.startSpan(allocator, "cache.set", "Cache user results");
            if (cache_span) |cache| {
                defer {
                    cache.finish();
                    cache.deinit();
                    allocator.destroy(cache);
                }

                try cache.setTag("cache.key", "users:active");
                try cache.setData("ttl", "300");

                std.log.info("Cache span created: {s}", .{&cache.span_id.toHexFixed()});

                // Simulate cache work
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
        _ = try sentry.captureMessage("User list retrieved successfully", .info);
    }
    // Flush to ensure all events are sent before shutdown
    std.log.info("Flushing events to Sentry...", .{});
    client.flush(3000); // 3 second timeout
}
