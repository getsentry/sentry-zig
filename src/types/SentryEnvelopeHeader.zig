const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SentryEnvelopeHeader = struct {
    sentry_id: SentryItemType,
    sdk_version: i64,
    trace_context: ?[]const u8 = null,
    sent_at: ?[]const u8 = null,
    unknown: ?[]const u8 = null,
};
