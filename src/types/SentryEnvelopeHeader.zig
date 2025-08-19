const std = @import("std");
const Allocator = std.mem.Allocator;

const UUID = @import("types").UUID;

pub const SentryEnvelopeHeader = struct {
    event_id: UUID,
};
