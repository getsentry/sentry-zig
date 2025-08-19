const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeHeader = @import("types").SentryEnvelopeHeader;
const SentryEnvelopeItem = @import("types").SentryEnvelopeItem;

pub const SentryEnvelope = struct {
    header: SentryEnvelopeHeader,
    items: []SentryEnvelopeItem,
};
