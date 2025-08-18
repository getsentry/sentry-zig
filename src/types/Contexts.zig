const std = @import("std");
const Allocator = std.mem.Allocator;

/// Contexts interface
pub const Contexts = std.StringHashMap(std.StringHashMap([]const u8));

/// Helper function to deinitialize Contexts
pub fn deinitContexts(contexts: *Contexts, allocator: Allocator) void {
    var outer_iterator = contexts.iterator();
    while (outer_iterator.next()) |outer_entry| {
        // Free the outer key
        allocator.free(outer_entry.key_ptr.*);

        // Deinitialize the inner StringHashMap
        var inner_iterator = outer_entry.value_ptr.iterator();
        while (inner_iterator.next()) |inner_entry| {
            allocator.free(inner_entry.key_ptr.*);
            allocator.free(inner_entry.value_ptr.*);
        }
        outer_entry.value_ptr.deinit();
    }
    contexts.deinit();
}
