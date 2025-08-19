const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeItemHeader = @import("types").SentryEnvelopeItemHeader;

pub const SentryEnvelopeItem = struct {
    header: SentryEnvelopeItemHeader,
    data: []u8,
};
