const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TransportResult = struct { response_code: i64 };
