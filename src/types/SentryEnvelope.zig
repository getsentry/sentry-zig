const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeHeader = @import("Types.zig").SentryEnvelopeHeader;
const SentryEnvelopeItem = @import("Types.zig").SentryEnvelopeItem;

pub const SentryEnvelope = struct {
    header: SentryEnvelope,
    items: []SentryEnvelopeItem,
};
