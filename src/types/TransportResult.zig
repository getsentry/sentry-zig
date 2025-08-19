const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SentryEnvelope = struct { response_code: i64 };
