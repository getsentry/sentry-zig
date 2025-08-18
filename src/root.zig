const std = @import("std");
const testing = std.testing;

// Re-export client types and functions
pub const SentryClient = @import("client.zig").SentryClient;
pub const SentryOptions = @import("client.zig").SentryOptions;
pub const Event = @import("client.zig").Event;
pub const Exception = @import("client.zig").Exception;
pub const User = @import("client.zig").User;

test {
    // Reference all tests in client.zig
    std.testing.refAllDecls(@import("client.zig"));
}
