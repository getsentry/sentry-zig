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

    pub fn deinit(self: *const SentryOptions, allocator: Allocator) void {
        if (self.dsn) |*dsn| {
            dsn.deinit(allocator);
        }
    }
};
