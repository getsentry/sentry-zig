const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeHeader = @import("SentryEnvelopeHeader.zig").SentryEnvelopeHeader;
const SentryEnvelopeItem = @import("SentryEnvelopeItem.zig").SentryEnvelopeItem;

pub const SentryEnvelope = struct {
    header: SentryEnvelopeHeader,
    items: []SentryEnvelopeItem,
};
