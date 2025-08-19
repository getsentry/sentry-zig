const std = @import("std");

test "test scopes" {
    _ = @import("scope.zig");
    _ = @import("transport.zig");
}

test "test transport" {
    _ = @import("transport.zig");
}
