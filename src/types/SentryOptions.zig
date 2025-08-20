const std = @import("std");
const Allocator = std.mem.Allocator;
const Dsn = @import("Dsn.zig").Dsn;

pub const SentryOptions = struct {
    dsn: ?Dsn = null,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    debug: bool = false,
    sample_rate: f64 = 1.0,
    send_default_pii: bool = false,

    // Tracing options
    traces_sample_rate: ?f64 = null, // null means tracing disabled, 0.0-1.0 enables tracing
    // TODO: Add traces_sampler callback once we solve the anytype comptime issue
    trace_propagation_targets: ?[][]const u8 = null, // URLs to attach trace headers to
    strict_trace_continuation: bool = false, // Validate org ID for trace continuation
    org_id: ?[]const u8 = null, // Organization ID for trace validation

    /// Deinitialize the options and free allocated memory.
    /// Note: environment and release strings are not freed by this method.
    /// The caller is responsible for managing the lifetime of these strings (as they are not owned by the client currently).
    pub fn deinit(self: *const SentryOptions, allocator: Allocator) void {
        if (self.dsn) |dsn| {
            dsn.deinit(allocator);
        }
    }
};
