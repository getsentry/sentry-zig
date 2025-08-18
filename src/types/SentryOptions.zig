const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SentryOptions = struct {
    dsn: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    debug: bool = false,
    sample_rate: f64 = 1.0,
    send_default_pii: bool = false,

    pub fn deinit(self: *SentryOptions, allocator: Allocator) void {
        if (self.dsn) |dsn| allocator.free(dsn);
        if (self.environment) |environment| allocator.free(environment);
        if (self.release) |release| allocator.free(release);
    }
};
