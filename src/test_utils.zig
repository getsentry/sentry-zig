const std = @import("std");
const Event = @import("types/Event.zig").Event;

/// Helper function to clean up events in tests
pub fn cleanupEventForTesting(allocator: std.mem.Allocator, event: *Event) void {
    // Clean up tags
    if (event.tags) |*tags| {
        var iter = tags.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        tags.deinit();
    }

    // Clean up fingerprint
    if (event.fingerprint) |fingerprint| {
        for (fingerprint) |fp| {
            allocator.free(fp);
        }
        allocator.free(fingerprint);
    }

    // Clean up breadcrumbs
    if (event.breadcrumbs) |breadcrumbs| {
        for (breadcrumbs.values) |*crumb| {
            crumb.deinit(allocator);
        }
        allocator.free(breadcrumbs.values);
    }

    // Clean up contexts
    if (event.contexts) |*contexts| {
        var ctx_iter = contexts.iterator();
        while (ctx_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var inner_iter = entry.value_ptr.iterator();
            while (inner_iter.next()) |inner_entry| {
                allocator.free(inner_entry.key_ptr.*);
                allocator.free(inner_entry.value_ptr.*);
            }
            entry.value_ptr.deinit();
        }
        contexts.deinit();
    }

    // Clean up user
    if (event.user) |*user| {
        user.deinit(allocator);
    }
}
