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

    /// Custom JSON serialization to output the envelope header in Sentry's expected format
    pub fn jsonStringify(self: SentryEnvelopeHeader, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("event_id");
        try jw.write(&self.event_id.value);
        try jw.endObject();
    }
};
