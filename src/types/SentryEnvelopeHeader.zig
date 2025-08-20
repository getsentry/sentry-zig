const std = @import("std");
const Allocator = std.mem.Allocator;

const EventId = @import("Event.zig").EventId;

pub const SentryEnvelopeHeader = struct {
    allocator: ?Allocator = null,

    event_id: EventId,

    pub fn init(
        allocator: Allocator,
        event_id: EventId,
    ) !SentryEnvelopeHeader {
        const event_id_copy = if (event_id) |event_id_capture| try allocator.dupe(u8, event_id_capture);

        return .{
            .allocator = allocator,

            .event_id = event_id_copy,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| if (self.event_id) |event_id| allocator.free(event_id);
    }

    /// Custom JSON serialization to output the envelope header in Sentry's expected format
    pub fn jsonStringify(self: SentryEnvelopeHeader, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("event_id");
        try jw.write(&self.event_id.value);
        try jw.endObject();
    }
};
