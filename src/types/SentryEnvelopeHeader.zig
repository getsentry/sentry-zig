const std = @import("std");
const Allocator = std.mem.Allocator;

const EventId = @import("Event.zig").EventId;

pub const SentryEnvelopeHeader = struct {
    event_id: EventId,

    // TODO: fix types and uncomment
    // sdk_version: i64,
    // trace_context: ?[]const u8 = null,
    // sent_at: ?[]const u8 = null,
    // unknown: ?[]const u8 = null,
};
