const std = @import("std");
const Allocator = std.mem.Allocator;
const Dsn = @import("Dsn.zig").Dsn;

pub const SentryOptions = struct {
    allocator: ?Allocator = null,

    dsn: ?Dsn = null,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    debug: bool = false,
    sample_rate: f64 = 1.0,
    send_default_pii: bool = false,

    pub fn init(
        allocator: Allocator,
        dsn: ?Dsn,
        environment: ?[]const u8,
        release: ?[]const u8,
        debug: bool,
        sample_rate: f64,
        send_default_pii: bool,
    ) !@This() {
        const dsn_copy = if (dsn) |dsn_capture| try dsn_capture.clone(allocator) else null;
        const environment_copy = if (environment) |env_capture| try allocator.dupe(u8, env_capture) else null;
        const release_copy = if (release) |release_capture| try allocator.dupe(u8, release_capture) else null;

        return .{
            .allocator = allocator,

            .dsn = dsn_copy,
            .environment = environment_copy,
            .release = release_copy,
            .debug = debug,
            .sample_rate = sample_rate,
            .send_default_pii = send_default_pii,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.dsn) |*dsn| dsn.deinit();

        if (self.allocator) |allocator| if (self.environment) |environment| allocator.free(environment);
        if (self.allocator) |allocator| if (self.release) |release| allocator.free(release);
    }
};
